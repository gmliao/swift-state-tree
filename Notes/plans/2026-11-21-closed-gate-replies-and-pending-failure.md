# A closed output gate stops every reply, and the keeper sees a pending failure before its next phase (#696, #704)

Rev 3, 2026-11-21. Plan only: no code until Review's GO. Code pointers are at main 7170a8e3, the current code; no source file changed since a7ed4d2b. "TA" is `Sources/SwiftStateTreeTransport/TransportAdapter.swift`, "LK" is `Sources/SwiftStateTree/Runtime/LandKeeper.swift`, "LR" is `Sources/SwiftStateTreeTransport/LandRouter.swift`.

Review on rev 2 returned NOT GO, with 2 must-fixes, both in the text. Rev 3 answers them:
- **The callers of a turn that ends get `landClosed`,** as the maintainer decided. §2.5 states the rule in the same words as #716's plan, and test 11 checks it.
- **`finishApply()` returns an enum and runs after the pass ordinal is taken,** as in #716 rev 6 (§2.3).

It also takes that verdict's shoulds and nits:
- the off mode stays uncovered until L2d-3 deletes it (§2.3);
- test 5 checks that a tick land's handler effects after a note are dropped;
- the census is a script that CI runs (§2.2);
- the router's direct sends are worded again (§2.1).

Rev 1 got NOT GO from Review, with 1 must-fix and 5 shoulds. Rev 2 made these changes:
- **The must-fix: a fourth closer.** The public `sendEvent` also closes the gate and then awaits the submit (TA:2726-2735). Every adapter-side closer now goes through one helper, a census test pins that, and a mutant covers `sendEvent` (§2.2). The debug freeze settle is a fifth closer of the same shape until L2d-1, and it goes through the helper too.
- **One end-of-apply function, shared with #716** (§2.3).
- **What the settle does** (§2.4).
- **One rule for the callers** of a turn that ends after its apply (§2.5).
- **The router's direct sends and the final frames,** listed (§2.1).
- **A test with no turn due** (§3).

It also names the window the note closes (§2.2), and adds a rule to the reentrancy notes (§4).

## 1. Both still reproduce on main

**#696: replies are enqueued after the gate closed.** The two answer helpers check only the answer's ticket before they enqueue:
- `sendActionResponse` (TA:5605-5608);
- `handleActionError` (TA:5675-5678).

`enqueueOutbound` → `enqueueFrames` (`TransportAdapter+Outbound.swift:16-33`) doesn't read `outputGate` either. Event sends and the sync commit read the gate themselves (TA:2991, :3031, :4240).

A reply can be enqueued in two windows:
- **After an adapter-side close, before the keeper applies the failure.** The adapter closes the gate in its own segment and then awaits `keeper.submitLandFailure` (§2.2 lists the closers). Meanwhile another action of the land can complete, and its answer goes out.
- **After the keeper's `failLand`, before the sessions close.** `failLand` closes the gate in the failing segment (`closeOutputs`, LK:5644). It then starts the teardown task, whose `landDidFail` closes the sessions with 4016 later (LK:5645-5648, hold `.landFailedTeardown` at :5646). In that window an action can still get an error reply: one submitted after the failure, whose `submitAction` throws, or a pending one whose job `cancelAllActionJobs` cancels.

**Other unchecked enqueues.** Every other frame through `enqueueOutbound` to this land's sessions is unchecked as well:
- the decode-error reply (TA:2492);
- the client-event error (TA:2697);
- `sendJoinError` (TA:5981) and `sendJoinResponse` (TA:6021);
- the router's JoinResponse and its frames to a joined or joining session (LR:1613, :1737, :1741).

**#704: a sync phase runs between an adapter's gate close and the failure.** The failure reaches the keeper only through the awaited `submitLandFailure` (LK:5541). That call queues it as a `.landFailure` input and kicks a server-input turn. Until a turn applies that input, the keeper doesn't know about the failure.
- Its in-turn sync phase (`runTurnOutputs` LK:4731, `runSyncOnlyTurn` LK:5162) calls `runSyncPhaseInTurnResult` (TA:2848). That plans and commits as usual: with the gate closed, only the commit's `enqueueFrames` is skipped (TA:4240).
- So, as the issue says:
  - the phase flips a waiting join and resolves its waiter, while the closed gate drops its JoinResponse and first sync;
  - a plan that throws reports its own `syncPlan` failure first, so the answer's `responseEncode` is dropped as a second cause;
  - after `setTransport` to another adapter (LK:475), the phase runs through the new adapter, whose gate is open.

Every closer in §2.2 has this window. The tests in §3 reproduce both bugs. Each test is written first and fails on main.

## 2. Design

### 2.1 #696: the gate is read where every frame is enqueued

`enqueueFrames` drops every frame when `outputGate.isClosed`, and counts the drops in `framesDroppedLandFailed`, as `initialSyncsDroppedLandFailed` does for first syncs. It is synchronous, so the check is in the same segment as the enqueue, which is the rule CLAUDE.md asks for.
- One chokepoint covers both answer helpers, the error and join replies, and the router's frames through the adapter, which today would each need their own check. A send site added later is covered too.
- The answer helpers keep their ticket check. A stale answer is still logged as stale (`droppedStaleActionAnswer`). One the gate drops is logged as dropped because the land failed.
- The existing gate checks (TA:2991, :3031, :4240) stay. The one at :4240 also keeps the commit from starting inbound drains.

**Not gated, by design:**
- **The final frames.** `sendFinalFrameAndClose` (`TransportAdapter+Outbound.swift:75`) writes through the outbound writer directly, not through `enqueueFrames`. It carries a close, which must still go out. Its callers:
  - a join ended before its admission, with its final frame (`endJoinBeforeAdmission`, TA:1789);
  - a session closed because its inbound frames went over the bound after its join (TA:2390);
  - the router's join failure (a timeout, an event overflow or an inbound overflow), whose error frame goes out before the close (LR:1420).
- **The 4016 closes** (`closeSessionsForLandFailure`, TA:3655), which `landDidFail` calls. They are the failure's own close.
- **The router's direct sends** (LR:1615, :1743). They go to `transport.send` only when the router finds no live adapter for the session. That happens while the session is still in the handshake, and also for a session still bound to a land whose instance has ended: `liveAdapter(of:)` returns nil once the land manager no longer has the instance live (LR:89-92). Such a session gets a router frame, for example the error for an undecodable frame. That is still router-level output: it isn't a frame of the failed land's turns, and that land's adapter is gone, so the land's gate doesn't apply to it.

An alternative is to check the gate at the two answer helpers only, which is #696's literal scope. It leaves the join and error replies open, so the chokepoint is recommended (§6 Q1).

### 2.2 #704: every adapter-side closer notes the failure on the keeper, through one helper

The adapter can't change keeper state, and the keeper is another actor. So the failure is made visible the way `isDraining` already is: through a lock-protected, set-once box that any isolation can read without an await.
- **The keeper gets `pendingTransportFailure`.** It is a box like `LandOutputGate`, where the first failure wins, with a `nonisolated` package method `notePendingFailure(_:)`.
- **One adapter helper owns the close.** `failOutsideTurn(_ failure:) async` does three things:
  1. it closes the gate (`outputGate.close`);
  2. in the same segment, it notes the failure on the keeper;
  3. after a hold point, it awaits `keeper.submitLandFailure`.

  It has a synchronous half, `closeAndNoteOutsideTurn(_:)`, which does steps 1 and 2 for a caller that closes in one segment and submits later.

  The awaited submit stays, so a land with no turn due still ends promptly (§3, test 10). When that queued input arrives, `failLand` finds the land already failing and keeps the first cause.
- **The closers.** Every adapter-side close outside a turn goes through the helper:

  | Closer | Today | With the helper |
  |---|---|---|
  | The public `sendEvent` (#535 row 17) | close and submit (TA:2734-2735) | `failOutsideTurn` |
  | An action response that doesn't encode | close (TA:5621), then `submitAnswerFailure` (TA:5629) | `failOutsideTurn` |
  | An action error reply that doesn't encode | close (TA:5691), then `submitAnswerFailure` | `failOutsideTurn` |
  | A joiner's first sync that fails | close and submit (TA:5268-5269) | `failOutsideTurn` |
  | The debug freeze settle that fails (until L2d-1) | close in the job (TA:6266), submit after it (TA:6214) | `closeAndNoteOutsideTurn` in the job; the submit stays where it is |

  `submitAnswerFailure` and its hold point `.answerFailureSubmit` (#701) fold into the helper. The hold point becomes `.failureSubmit`, held between the note and the submit. #701's tests move to it.
- **In-turn closes stay as they are.** The in-turn event loss (TA:2866) returns `.landFailed` to the keeper's turn, which calls `failLand` in that turn. The keeper's own `closeOutputs` (`+LandKeeperTransport.swift:93`) runs in `failLand`.
- **A census pins the list.** A script, `scripts/gate-close-census.sh`, in the shape of `scripts/l2c-census.sh`, finds `outputGate.close(` in the adapter's sources only in the helper and at the in-turn site. CI runs it in the PR's workflow, so it doesn't depend on a test reading source files. A new closer that skips the helper fails it. A mutant replaces `sendEvent`'s helper call with today's two lines, and the `sendEvent` window test (§3, test 6) must fail.

**The window the note closes.** The window runs from the close to the turn that applies the queued `.landFailure`. It has two parts:
- (b) **The cross-actor hop.** `submitLandFailure` awaits the keeper. The keeper may be in another turn, or have one queued ahead of the submit: a tick turn behind the tick task, a requested sync-only turn, or a held tick job. That turn runs before the failure is queued at all.
- (a) **Behind a queued item.** After the submit is queued, a sync-only turn doesn't take pending inputs, so it still runs its phase until the server-input turn applies the item.

The note covers both parts, because every keeper turn reads the box before its outputs (§2.3).

### 2.3 Where the keeper reads the note: one end-of-apply function, shared with #716

#716's plan (§3.1a, rev 6) adds `finishApply() -> ApplyEnd`, whose two cases are `.proceed` and `.ended`. Both plans use that signature. The keeper calls it once, right after each apply segment returns, and before anything of the turn goes out. It runs only when the apply hasn't already failed the land: a land that failed at an input takes today's failure branch. It does two things, in this order:
1. `applyPendingTransportFailure()`: if the box holds a failure, it calls `failLand` with it. The failure keeps its own position stage (`actionResponse`, `syncPhase` or `eventFlush`).
2. #716's depth preflight.

The first `failLand` wins, so a noted transport failure stays the cause. Whichever plan lands first adds the function. This plan adds it with step 1 only, and #716's S1b adds step 2.
- **The turns with an apply** call `finishApply()` at the in-turn segments of #716's table: initialize, the tick turn and the input turn. When it returns `.ended`, the turn takes its failure branch: no events and no sync. In `runInputTurn` the call goes after `takePassOrdinal` (LK:5790) and before `if failure != nil` (:5795). Called earlier, `failLand` would see no pass in progress and use the last pass (`lastPass`, LK:5596), so the failure's position wouldn't name the pass that ended.
- **The off mode stays uncovered until L2d-3 deletes it.** This plan adds no call to the legacy `runTick`, `processPendingActions` or `finishTicklessLegacyPass`, which L2d-3 removes. A land in the off mode keeps today's window until then.
- **The sync-only turn** has no apply. `runSyncOnlyTurn` (LK:5162) calls `applyPendingTransportFailure()` first, and skips its phase when the land ends.

After the note, no join flips and no plan runs, and the answer's failure is the first cause. A rebind doesn't escape either, because the note sits on the keeper, not on either adapter.

**What the note can't close.** The only gap left is the hop from an awaited encode to its segment. A phase that runs in another actor turn before the answer's encode runs before the failure existed, which is correct.

**Live only.** The adapter closers run only on a live land, and replay has no adapter. In re-evaluation the box stays empty.

An alternative is to let `runSyncPhaseInTurnResult` read its own gate and return `.landFailed(outputGate.failure)`. It is simpler, but it misses the rebind, and it leaves the keeper's own work in that turn unaware of the failure. So the keeper-side note is recommended (§6 Q2).

### 2.4 The freeze settle, and L2d

L2d-1 makes the freeze settle a sync-only turn. Its fence checks `failure == nil && !isDraining` before its phase.
- **The settle runs `applyPendingTransportFailure()` first.** When that ends the land, the settle returns `.failed(f)` with the noted failure, and its phase doesn't run.
- **Its `.skipped` mapping** ("a closed gate gives `released`") stays for a released freeze. A noted failure is `.failed`, not `.skipped`.
- **Order between the PRs.** Whichever of this PR and L2d-1 lands second adds those two lines. This plan's PR can go first: it touches `runTurnOutputs` and `runSyncOnlyTurn` with one call each, which L2d rebases over. Once L2d-1 has landed, the settle's job no longer closes the gate outside a turn, and its row in §2.2 goes.
- **L2d-2/3 and #700.** The end-of-apply function is one keeper function, so it survives L2d-2/3 unchanged. #700 calls it as the last act of a step's apply, under #716's rule that no `turn.emit` comes before it.

### 2.5 The callers of a turn that ends

**The callers of a turn that ends** (maintainer decision, 2026-11-21). A turn ends the land when `finishApply()` returns `.ended` (a noted transport failure or a depth refusal), when its in-turn sync phase fails the land, or when one of its inputs fails it (`.input`, #535). Then every caller whose input is in that turn's consumed batch gets `landClosed`, not its handler's outcome, and that includes a caller whose handler threw. The one exception is the input that failed the land: its caller gets that input's own error. No output of that turn is sent, replies included.
- **Where.** On `.ended`, the turn sets every consumed item's result to `landClosed` before `resumeInputTurnWaiters` (LK:5818-5826) resumes the callers. That covers the three places that resume them: the input drain (:5750), the replay passes (:4238), and the turn's own outcome store (:5803-5806). A tickless action job's slot (`ticklessJobTurns`, `fillActionSlot`) is filled from the same result.
- **Today's in-turn sync failure follows the rule.** A turn whose `runTurnOutputs` (:5802) fails the land keeps its outcomes today (:5806). From this change on, its callers get `landClosed` too, with a test.
- **Scope limit.**
  - A tick land acknowledges an action at submit (LK:2339). That reply belongs to the admission, not to the turn that later applies the action, so it stays.
  - A tick land's waiting join gets `landClosed` through the drain (LK:5701).
  - A turn that fails at an input (`.input`, #535) is under the rule too (Main's call, 2026-11-21, for the maintainer to confirm). Today the rest of its consumed batch keep their outcomes (:5806); from this change on they get `landClosed`, as in a turn that ends after its apply. That turn doesn't call `finishApply()`; it takes the existing failure branch, which sets the results the same way.
- **The record.** It keeps those inputs as applied, with the rejected list. A recorded input has no outcome field (`ReevaluationRecordedAction`, `ActionRecorder.swift:741-750`), so replay has no caller outcome to compare, and no mismatch can arise.
- **The test.** An input whose handler returned success, in a turn that ends, answers `landClosed`, and no frame of that turn reaches the transport. In a turn that fails at an input, that input's caller gets its error, and an earlier input of the same batch whose handler returned success answers `landClosed`.

### 2.6 One PR for both

Yes. Both bugs are on the path where an adapter closes the gate outside a turn:
- #696 is the frames that leak after the close;
- #704 is the keeper work that runs after it.

The tests share the `.failureSubmit` hold and one fixture. The PR has two commits: the `enqueueFrames` gate (#696), then the helper, the note and the end-of-apply function (#704). Estimated size: Sources about +100 / −20, Tests about +380.

## 3. Tests (each fails on main first; holds, never timing)

Hold points:
- `.failureSubmit` (today's `.answerFailureSubmit`, TA:30, #701), between a closer's note and its submit;
- the keeper's `.landFailedTeardown` (LK:5646), between `failLand` and `landDidFail`.

**#696:**
1. **Adapter-side window.** On a tickless land and on a tick land, under each compressed encoding:
   - Action A's response doesn't encode (the untyped-payload fixture, `UntypedEventPayloadTests`), and A holds at `.failureSubmit`.
   - Action B then completes normally. B's reply never reaches the transport, and `framesDroppedLandFailed` counts it.
   - After the release, the land ends with A's `responseEncode` and the session closes with 4016.
   - The same runs with B's error reply (B's `validate` throws).
2. **Keeper-side window.** A land fails (`failLandForTesting`) and holds at `.landFailedTeardown`. An action is sent in that window. No error reply reaches the transport, and the session still closes with 4016 after the release.
3. **Join and router frames.** With a closer held at `.failureSubmit`, a join request gets neither a JoinResponse nor a join error. The router's path is covered by a router-level join of the same land.
4. **The final frames still go out.** After the gate closed, a join ended before its admission still gets its final frame and its close (TA:1789), and the 4016 close still reaches every session.

**#704:**

5. **Join flip.** A holds at `.failureSubmit`, with a join waiting for its flip. A sync turn runs: a tick, or a requested sync-only turn on a tickless land. The join doesn't flip, and its waiter isn't resolved as joined. The land ends with `responseEncode`. On the tick land, the tick handler's effects in that turn are dropped: no event of that tick is sent, and its record has no state hash.
6. **`sendEvent`.** On a MessagePack land, a `sendEvent` whose event doesn't encode holds at `.failureSubmit`, and a sync turn runs. No commit runs, and the land ends with `eventEncode`.
7. **First cause.** The same hold as test 5, with the sync plan made to throw (`syncPlanFaultForTesting`). The land's failure is A's `responseEncode`, not `syncPlan`.
8. **Rebind.** During the hold, `setTransport` moves the keeper to a second adapter, and a sync turn runs. The second adapter's transport gets no state frame, and the land ends with A's failure.
9. **The first-sync closer** (TA:5268): a joiner's first sync fails (`firstSyncPlanFaultForTesting`), and another sync turn runs before its submit. No commit runs after the close.
10. **No turn due.** On a tickless land with no requested sync, a closer notes its failure, and no keeper turn runs before the release. After the release, the awaited submit ends the land with the noted failure, which stays the first cause.
11. **Callers get `landClosed`.** An action whose handler returned success, applied in the turn that `finishApply()` ends, answers `landClosed`, and no frame of that turn reaches the transport (§2.5). A turn whose in-turn sync phase fails the land answers its callers the same way.
12. **#701's pins stay.** They assert that the land hasn't failed yet during the hold. With the note, that still holds while no keeper turn runs, which the pins don't do. The pins gain an assert that the failure is noted.
13. **The census** (§2.2): the script finds `outputGate.close(` only in the helper and at the in-turn site, and CI runs it.

**Mutants** (each restored afterwards; each must fail a test):
- the gate check in `enqueueFrames` removed;
- `sendEvent` back to its own close and submit, without the helper;
- the note removed from the helper;
- `applyPendingTransportFailure` skipped in `finishApply`, and in `runSyncOnlyTurn`;
- the note box made last-wins.

## 4. Steps, verification, docs

- **S1, one PR in the core:** the two commits of §2.6, with the tests first. The second commit also adds `scripts/gate-close-census.sh` and its CI step.
- **On the Mac:**
  - build;
  - the touched suites: `UntypedEventPayloadTests`, `ActionErrorReplyEncodeTests`, `TransportAdapterJoinFlipTests` and the router join suites;
  - the census script;
  - the mutants.
- **On CI:** the full `swift test` and E2E.
- **A/B: none.** The change adds one lock read per enqueue and one per turn. The same lock is read today, in `isClosed`, on every event send.
- **Docs,** en and zh-TW: `docs/core/failure-handling.md`.
  - The gate rows say that a closed gate drops every reply and join frame, not only state and event frames. The final frames and the 4016 close still go out.
  - They also say that the keeper ends the land in its next turn, before any output, after an adapter-side failure.
  - The #701 rows (encode before the ticket check) are unchanged.
- **The reentrancy notes.** CLAUDE.md's reentrancy section and `Notes/plans/2026-11-05-reentrancy-helpers.md` gain one rule. *A failure found outside a turn goes into a set-once mailbox on the keeper in the segment that finds it. The keeper reads that mailbox at each step boundary, and the async submit only wakes the keeper.* The plan file changes in this PR. CLAUDE.md changes on the maintainer's OK, as L2d-3 does.
- **Solutions:** an entry on the lesson. A gate checked at each send site leaks at the next site added, so check it where frames are enqueued. Its index row goes in the same change.

## 5. Fit with #716

#716 rev 5 (§3.1a) has the end-of-apply function and the callers' rule (its Q5). This plan adds the function with the transport step, and #716's S1b adds the depth step. If #716's S1b lands first, which can't happen before L2d-3, this plan adds its step to the existing function instead.

## 6. Questions

- **Q1:** the gate at `enqueueFrames` (every frame, recommended), or at the two answer helpers only (#696's literal scope)?
- **Q2:** the keeper-side note (covers the rebind, recommended), or the phase reading its adapter's gate (smaller, misses the rebind)?
- **Q3, decided 2026-11-21 by the maintainer:** the callers of a turn that ends get `landClosed`, handler errors included, and no output of that turn is sent, replies included (§2.5). #716's Q5 is the same decision.

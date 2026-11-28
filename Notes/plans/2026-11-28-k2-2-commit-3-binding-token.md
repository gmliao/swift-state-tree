# K2-2 commit 3: the binding token (#700)

Rev 3 (2026-11-28), plan only. It answers Review's verdict on rev 2: MF1–MF5, four shoulds and three nits. Rev 2 ran and quoted the probes (§4); rev 1 only listed them.

This plan details the K2-2 plan's commit 3 (`2026-11-27-k2-2-cut-over-the-keeper-onto-the-core.md`: §3 commit 3, §3.2, §9 and §10) and the K2 plan's §4.5 and §18 item 19.

Code is read at main 3530a4c2. File abbreviations:

| Short | File |
|---|---|
| LK | `LandKeeper.swift` |
| KM | `KeeperMachine.swift` |
| TS | `KeeperTurnSide.swift` |
| TA | `TransportAdapter.swift` |
| TAK | `TransportAdapter+LandKeeperTransport.swift` |
| LKT | `LandKeeperTransport.swift` |
| CDT | `KeeperCoreDifferentialTests.swift` |

## 1. Goal

Lift every core refusal that waits for the binding token, so that commit 4's precondition holds for this group.

- `KeeperCoreRefusalReason.joinSyncingInTurn` and `.ticklessLandWithTransport` are deleted (KM:347).
  - Once #983 deletes `.joinAwaitingLeaveInFlight` (KM:357, 364 at 3530a4c2), `refusalReasonsAreNamed` expects an empty set.
  - If this commit lands before #983, the set left is `["joinAwaitingLeaveInFlight"]`.
- The three sync follow-ups run on the core as core requests, not as refusals (`refusesSyncFollowUpOnCore`, LK:7233). They are:
  - `scheduleJoinSyncTurn`
  - `requestSyncTurnAfterThisTurn`
  - `retrySyncOnlyTurnAfterWriterDrain`
- `requestJoinSyncTurn` (LK:2114, package) gets a core route.
- The tickless `.admitServerInput` precondition (KM:953) goes.
- The core-side `actionTableViolations` kinds for requested sync work and pending follow-ups (LK:5457–5466) are replaced by a check at quiescence (§3.4).
- These are deleted:
  - `carriedSyncsInTurn` (KM:314, TS:280), K2-1's stand-in, with its check at LK:5464–5466;
  - `KeeperOutput.bindTransport` (KM:456), declared and never emitted;
  - `KeeperKey.syncBinding` (KM:16), unused.

No public API changes. Section 3.6 records one change in how a public protocol behaves. The admission path is a package protocol refinement (§3.3).

## 2. What the code does today

- **The keeper's attach.** `setTransport(_:)` (LK:570–584) is synchronous. In order:
  1. A re-entry (`bodyDepth != 0`) is refused through `noteReentry(through: "setTransport")` (LK:4138–4158). That counts the violation, notes the pending failure and closes the outputs of the attached port, the bound requester or `reentryGateForTesting`. The land then ends.
  2. Unless `destructionFinished`, a live keeper whose port answers `runsSyncPhaseInTurn(of: self)` false traps (`refuseTransportWithoutInTurnPhase`, LK:589).
  3. It attaches `destructionFinished ? releasedTransport : transport`, without asking the witness after the destruction. It writes `transport`, `turnSide.attachedTransport` and `model.transportRecordsFolds`.
  4. Only for a non-nil port before the destruction, it runs `noteTransportBound` (LK:4392). That sets `hasHeldTransport`, clears the bound requester and rebinds `syncBinding`. So **`setTransport(nil)` doesn't rebind**: a ticket made before a detach stays current.

  `releasedTransport` is a private field of the keeper (LK:608), set when the destruction finishes (LK:4931).

  The callers are:
  - `LandManager`, after its wiring hold (LandManager.swift:711–712). Eager initialization may already be running then (LK:1290–1293).
  - The drain's own `setTransport(nil)` (LK:4932).
  - Benchmarks and tests.

  The adapter never calls it.
- **The core's attach.** The side gets its port once, when `coreTwinForTesting(transport:)` builds it (LK:2221). No input changes it. `.detachTransport`'s flush only logs. `.drainFinished` only emits `.detachTransport` (KM:715–723).
- **The port's answer is fixed per binding.** The adapter's `runsSyncPhaseInTurn(of:)` is `keeper === self.keeper` (TAK:29, TA:118), and `keeper` is a `let` (TA:93). P1 found no test port whose answer changes within an attachment.
- **How a body reads it on the core.** `side.syncsInTurn(behavior)` (TS:278–285) uses `carriedSyncsInTurn` when a tick, sync or `.syncTurnNow` step set it. Otherwise it asks the port through `keeperReference.keeper`, which a core's side leaves empty, so the answer is false. Every other step (a join, the input drain, the initialization, `.recordTaken`) would read false where the keeper reads true. That is why the two shapes are refused.

## 3. The design

### 3.1 The binding lives on the side, set by a `.control` step (MF1, MF2)

**The input.** `KeeperInput.setTransport(port: (any LandKeeperTransport)?, syncsInTurn: Bool)`.
- Its policy is `.control`, added to `inputPolicy`'s list (KM:500–505). A `.normal` input is refused on a closed intake (TurnActor.swift:361–364, 388–392), and the keeper's attach is never refused for that reason.
- The policy depends on the input alone, as `inputPolicy` requires.

**The sender, in the keeper's order.** In K2-2a's shape the harness sends it; from commit 4 the facade forwards `setTransport` to it. The sender runs on the actor, between steps, and in one segment:
1. **The re-entry.** If the core is stepping (the harness's check now; the facade's `isStepping` in commit 4), it refuses as the keeper does. The refusal does what `noteReentry` does, on the side: it counts the sentinel's violation, notes the pending failure and closes the attached port's outputs (or the bound requester's). It sends nothing. The enclosing step's re-entry check then ends the land in that step, as `callOut` does on the keeper, and the attach never steps. P2 showed that a send from a step would otherwise be queued and applied.
2. **The destruction.** It reads `destructionFinished` (`core.read`). Once that is true it never goes back to false, so a read of true still holds when the input steps. If it is true, the sender skips the witness and sends `syncsInTurn: false`.
3. **The witness.** Otherwise, for a non-nil port that is not the released stand-in, it asks `port.runsSyncPhaseInTurn(of: owner)` once. On a live core a false answer traps, with the keeper's message (`refuseTransportWithoutInTurnPhase`). It sends the answer as `syncsInTurn`. A nil port sends `false`.

**The step.** The keeper's steps 3 and 4:
- `let attached = destructionFinished ? side.releasedTransport : port`. The step reads the flag again: a `.drainFinished` queued ahead of it may have set it after the sender's read.
- It writes `side.attachedTransport = attached` and `side.attachedSyncsInTurn = (attached === port) && syncsInTurn`, and sets `transportRecordsFolds` from `attached`.
- Only for a non-nil port before the destruction, it does `noteTransportBound`'s writes: `hasHeldTransport`, the bound requester cleared, `syncBinding.rebind()`. A nil port doesn't rebind (§2).

**The released stand-in on the side.** `side.releasedTransport: ReleasedLandTransport?` is a new side field with a census row. `.drainFinished`'s step creates it, attaches it (`attachedTransport = releasedTransport`, `attachedSyncsInTurn = false`), and clears `transportRecordsFolds`. That is the keeper's `releasedTransport` followed by `setTransport(nil)` (LK:4931–4932), done in the step. The keeper keeps its own field until K2-3.

**Why the Bool lives on the side.** `side.syncsInTurn(behavior)` (TS:278) gets no model, and a model field would enter `CoreDiffDigest` (CDT:882–904) as a stated asymmetry. So `attachedSyncsInTurn` sits next to `attachedTransport`. On the core, `syncsInTurn` returns `behavior.config.mode == .live && attachedTransport != nil && attachedSyncsInTurn`. The keeper's side keeps asking the port.

**Why a stored binding is the keeper's read.** The keeper re-reads `self.transport` and asks the port at each use, after every await. On the core every stage after an await is its own step, and a step that reads the stored binding reads it at that point, after the await. The binding changes only in `.setTransport`'s and `.drainFinished`'s steps, so no step can read a binding that was replaced in between. The port's answer can't change within a binding (§2, P1), so reading it once at the attach gives the value the keeper gets at each use.

This replaces the K2 plan's "the token rides the inputs that need a port" (§4.5). Review accepted it on rev 2's Q1, on condition that MF1 and MF2 land.

**The read sites** (MF2):

| Site | What it reads on the core | Code |
|---|---|---|
| The initialization's sync check | the stored binding | `initializeTurnBody`, LK:8521; check at :8561 |
| The tickless input drain | the stored binding | `inputTurnBody`, LK:8600; check at :8640 |
| The join's admission and its stale-join and consumed-join calls | the stored binding | `.admit` arm, KM:1569–1583 (§3.3) |
| `.recordTaken`'s drain | the stored binding | KM:525 |
| The tick and the sync step | the stored binding, read at their step. `carriedSyncsInTurn` goes. Their input's `syncsInTurn` field is deleted: the sender no longer reads it. | KM:1229, 1441 |
| `.syncTurnTicket`, `.syncTurnNow`, `.settle` | their own named port, per call: the witness is asked in the query arm, after the land-state checks, as now | KM:969–1007 |
| The bound-requester path (no port ever attached) | the named requester, held weakly; its witness is checked when it binds | LK:7046–7068, TS:379 |

**Order against the initialization** (MF1). `LandManager` attaches after its wiring hold, while eager initialization may run (LK:1290–1293). On the core, `.initialize`'s flow is several steps, its resolvers' effect in between, and `.setTransport` steps wherever it arrives. 3a's cases attach at three points:
- before `.initialize`: the initialization's sync check reads true;
- while its resolvers are held: the attach steps, then `.initializeDone`'s body reads true;
- after `.initializeDone`: the initialization read false, then the attach rebinds.

Each is compared with the keeper attaching at the same hold point (`LandManager`'s `.wiring` hold, or a test hold at the initialization's resolvers).

### 3.2 The tickless land with a transport (MF3, server input)

With §3.1 in place, the tickless input drain (`inputTurnBody`, LK:8600, its check at :8640) reads the same `syncsInTurn` as the keeper and runs `runTurnOutputs` on the core. The refusal is deleted. The initialization reads the same binding (§3.1's table), which covers the survey's possible gap: today a tick land's `.initialize` with a transport reads false on the core.

**Server input.** A query can't queue, so on a tickless land the intake becomes `KeeperInput.serverInput(input)`, a `.normal` call whose reply is the `ServerInputOutcome`. A tickless client event is already `.clientEvent`, not a query, for the same reason. A tick land keeps the `.admitServerInput` query.
- The step runs `serverInputIntake` (LK:5160–5171) as it is. It already calls `kickServerInputTurn` (LK:8920–8929), which begins the work count (`debugBeginWork`), except while frozen, when the input waits outside the queue (LK:5165–5168). This plan adds no second `debugBeginWork`.
- On a core, `kickServerInputTurn` stages nothing. It records the kicked sequence on the side, `side.coreInputReplies.serverInputKick = sequence`.
- After the step, the arm reads that field and clears it. For a kicked input it registers the kick's wait, `waits[sequence] = .serverInputKick`, as the resume does (KM:598–612). It queues `.inputDrainDue` behind `.land` if the step scheduled the drain, as `.actionResolved` does (KM:585–592).
- The wait ends in the input turn that applies the sequence (KM:1886: `debugEndWork`).
- An accepted input while frozen kicks nothing, and the resume kicks it later (KM:838–850). So the work begins once per input.

**The admitted join's drain.** `joinAfterAdmission` on a tickless land with `.admittedCompletesInTurn` calls `scheduleInputDrain` (LK:6595–6601). On a core that only sets the flag (LK:5966–5976). The `.admit` arm copies `.actionResolved`'s shape: it reads `inputDrainScheduled` before the step and queues `.inputDrainDue` behind `.land` if the step set it (§3.3).

`shutdownBatchThatFailsTheLand` (CDT:2570) is enabled: it was disabled only by this refusal.

### 3.3 The join that syncs in the turn (MF3, MF4)

The keeper's join re-reads the binding at the admission, between segments (`admitJoiningInTurn`, LK:2095), after up to three awaits: the CanJoin resolvers, the kick or the leave wait, and the OnJoin resolvers. On the core, `.admit`'s stage is a step that reads the stored binding there (§3.1). The `precondition(!syncsInTurn)` at KM:1573 goes.

**The admission's port call.** It can't call back into the keeper during a step (K2 §4.5's audit). `admitJoiningSession` reaches `recordSyncStreamClear` on a supersede, which calls the keeper twice: `keeperRecordsSyncStream` (TA:3876) and `submitSyncStream` (TA:4027–4033). Inside a step the second is refused and the land ends. So:

- **A package protocol refinement.** It has the shape of `LandKeeperSettlePort` (LKT:303–315). The core dispatches with `port as? any LandKeeperInStepAdmissionPort`. A package extension method on the public existential would dispatch statically and never reach the adapter's version, so it isn't used.
  ```swift
  package protocol LandKeeperInStepAdmissionPort: LandKeeperTransport {
      func admitJoiningSessionInStep(playerID:clientID:sessionID:joinSequence:recordsSyncStream:) -> (JoinAdmission, [SyncStreamDraft])
  }
  ```
  - `TransportAdapter` conforms in TAK, next to `LandKeeperSettlePort`. It runs the same admission, with the supersede's clear built as drafts and returned, not submitted.
  - `recordsSyncStream` is passed in (`side.recordsSyncStream(behavior)`), so the adapter doesn't ask the keeper.
- **A port that doesn't conform** (test ports) gets `admitJoiningSession` and no drafts. **Its safety contract:** its admission must not call back into the keeper. A call back is caught, because the admission now runs inside a step and through the step's re-entry check (below). The land ends there, as on the keeper. 3b's differential states which test ports conform.
- **Where it runs.** Today the admission runs outside `step(...)` (KM:1575), and the violations snapshot is taken at the step's entry (KM:1186), so a re-entry from the port isn't seen. In 3b it runs inside one step body, in the shape of `.syncStreamDraft` (KM:672–676):
  ```swift
  let drainWasScheduled = inputDrainScheduled
  let admitted = step(behavior, store) { m, side, outputs in
      let before = behavior.reentrySentinel.reentryViolations
      let (admission, drafts) = /* the refinement's call, or admitJoiningSession with [] */
      m.recordSyncStream(behavior, side, drafts, outsideTurn: false)
      if behavior.reentrySentinel.reentryViolations != before { _ = m.applyReentryFailure(behavior, &side, &outputs); return nil }
      return admission
  }
  ```
  The drafts are recorded with `outsideTurn: false`, as the keeper's clear is recorded during the join's admission (LK:4262–4273, 6712–6724; TA:2003). That is right after the admission, before `joinAfterAdmission` and before the J3b reply (KM:1576–1579), so the clear keeps its place in the record. Then `joinAfterAdmission` runs, and the drain is queued as in §3.2.
- **The keeper's own path** keeps `admitJoiningSession` until K2-3 deletes that path.
- **The joined response** is the router's closure (LandRouter.swift:1063–1077). It is unchanged: it awaits the keeper's join call, which the facade answers in commit 4.

**`requestJoinSyncTurn`** (LK:2114–2127, package) has no route. The adapter calls it after a registration (TA:2364) and on a resume (TA:6518). It becomes `KeeperInput.requestJoinSyncTurn`, `.normal`, whose step runs the method's body against the stored binding: the draining check, `transportHasJoinsAwaitingSync` through `callOut`, the periodic-sync guard, the counter and one sync-only turn. On the keeper it stays a method until commit 4's facade forwards it.

**The test seam** (MF4, should 1). The adapter's `keeper` is the `LandKeeper` (TA:93), and `performJoinQueued` fills `expectedAdmissions` (TA:2022, 2298). So `SyncStreamLeaveReplayTests.supersedingJoinWithOnJoinRecordsItsClear` (SyncStreamLeaveReplayTests.swift:217–235) can't drive the core before commit 4. 3b tests the parts instead:
1. An adapter case. `admitJoiningSessionInStep` on a superseding admission returns the drafts that `recordSyncStreamClear` would have submitted, and submits none. It is compared with the keeper's recorded clear in P4's golden.
2. A differential case with a test port that conforms to the refinement and returns fixed drafts. The core's record has the drafts at the admission's place, the same as the keeper's with a port that submits them.
3. A case where a port's admission re-enters the keeper. The land ends in the admission's step on both paths.

The full golden through the core is commit 4's, once the facade is the adapter's keeper. It is listed in the K2-2 plan's §13.6.

The differential also gets a syncing-join case per shape (tick and tickless, with and without join resolvers, with and without OnJoin), plus a supersede case, each with `violations == []`.

### 3.4 The three sync follow-ups (MF5)

**The core shape: a request for `.land`, a later job.** Each follow-up is `turn.request(.syncFollowUp(kind, port), for: .land)` (Turn.swift:150–176). Its result is an input, `.syncFollowUpDue(kind, ticket)`, that steps in a later job. Review's Q3 answer was a later-job effect. The reasons:
- **Not a timer.** A timer on a key that was never started is a no-op (Turn.swift:215–216), and `end`/`endAll` drop it without a step (Turn.swift:84–91, 112–137), so `requestedSyncWork` would leak.
- **Not `queue(_, behind: .land)`.** `.land` is never held, so a queued input steps in the same segment (TurnActor.swift:838–901), even before a `.syncTurnNow` query returns (TurnActor.swift:103–108). The keeper stages a Task for a later job (LK:7192–7197).
- **A tracked request.** It is counted by `waitForQuiescence(.requests)`. If `endAll` closes it first (commit 4), it is abandoned through `handleAbandoned(.keyEnded)`, which the model implements for these requests. An untracked `run` would be neither counted nor abandoned.

The effect's `perform` (the owner's executor in commit 4, the harness now):
- for the join sync turn: sleeps `delay` if it is above zero, then returns `.syncFollowUpDue(.joinSyncTurn, ticket)`. The only caller passes `.zero` (LK:7138).
- for the follow-up after this turn: returns `.syncFollowUpDue(.afterTurn, nil)` at once.
- for the writer-drain retry: awaits `port.waitForWriterDrainForInTurnSync()` (TAK:75–79), then returns `.syncFollowUpDue(.writerDrain, ticket)`. The adapter's wait returns once the writer drains, or once its consumer ends: `onLandDestroyed` finishes the writer (TAK:127–135). So the effect ends during the drain, and holding the actor strongly (TurnActor.swift:1065–1075) ends with it. The dropping port's default returns at once (LKT:471).

The model keeps `syncFollowUpRequests: [RequestID: SyncFollowUpKind]`, so the result and the abandonment retire the right kind.

| Follow-up | On the keeper | The request's input | Its step |
|---|---|---|---|
| `scheduleJoinSyncTurn` (LK:7241–7262) | a staged Task: sleeps `delay`, then `runJoinSyncTurn` (LK:4370) | `.syncFollowUpDue(.joinSyncTurn, ticket)` | `runJoinSyncTurn`'s body: clears `joinSyncTurnBinding` if it is this ticket, then runs the turn only if `!isDraining`, joins still wait (through `callOut`) and `acceptsSyncTurn(through:)` holds |
| `requestSyncTurnAfterThisTurn` (LK:7172–7197) | `pendingSyncTurnAfterTurn` on the side, and a staged Task that runs `runPendingSyncTurnAfterTurn` (LK:4467–4473) | `.syncFollowUpDue(.afterTurn, nil)` | **reads the slot, not a ticket of its own**, as LK:4467–4473 does: a nil slot means `.syncTurnNow` consumed it (LK:4456–4462), and the work already ended there. A slot replaced by a newer binding (LK:7183–7188) takes no second request, and its one request runs the newest slot. |
| `retrySyncOnlyTurnAfterWriterDrain` (LK:7203–7225) | a staged Task: `await transport.waitForWriterDrainForInTurnSync()`, then `runRetriedSyncOnlyTurn` (LK:4361) | `.syncFollowUpDue(.writerDrain, ticket)` | clears `inTurnDrainRetryBinding` if it is this ticket, then `runFollowUpSyncOnlyTurn` |

**`.syncTurnNow`'s consumption.** On a core a pending follow-up is now possible, so the assert at KM:995 (`side.pendingSyncTurnAfterTurn == nil`) goes. The arm does LK:4456–4462: if the pending slot names this port, it clears the slot and ends its `requestedSyncWork`. The request stays open, and its result finds the slot empty.

**`requestedSyncWork` ends exactly once per begin.** The begins are the three sites' `beginRequestedSyncWork` (LK:7071), unchanged. The ends:
- The result's step, for `.joinSyncTurn` and `.writerDrain`.
- For `.afterTurn`: the result's step if the slot is still there, or `.syncTurnNow`'s consumption, never both.
- `handleAbandoned(.keyEnded)`, for a request that `endAll` closed. For `.afterTurn` only if the slot is still there.

`requestedSyncWork` is not `debugInFlightWork`, and LK:7172–7264 never touches the latter.

**The check at quiescence replaces the audit.** The core-side violation kinds at LK:5457–5466 go. The differential's `expectSame` waits for the core's `waitForQuiescence([.followUps, .requests])`, then asserts `requestedSyncWork == 0`, `syncFollowUpRequests.isEmpty`, `pendingSyncTurnAfterTurn == nil`, `joinSyncTurnBinding == nil` and `inTurnDrainRetryBinding == nil`. On the keeper's path, `waitForRequestedSyncWork` is already used. A case for each follow-up at the drain's start also ends with this check: the request's result finds the land draining, or the writer wait ends with the destroy.

`refusesSyncFollowUpOnCore` and its three call sites go. `syncFollowUpsAreRefusedOnTheCore` becomes a twin case per follow-up and turn kind. It compares the two paths' counts (`requestedSyncTurnsForTesting`, `joinSyncTurnsScheduledForTesting`, `joinSyncTurnsForTesting`) and the sync-only turn that follows. The follow-ups' redesign stays K3's (K2 §18 item 19).

### 3.5 Slicing (Q2)

One PR with three commits, per the batch rule for overlapping files and tests. Review's Q2 answer pointed out that LK:7135–7153 arms the follow-ups from a tickless input turn as soon as 3a lifts the refusal. So 3a alone would leave the core refusing follow-ups that its own lifted turns now reach.

1. **3a: §3.1, §3.2.**
   - In: `.setTransport` as a `.control` step, the side's `attachedSyncsInTurn` and `releasedTransport`, the read-site table, the tickless server input as an input, and the admitted join's drain.
   - Out: `carriedSyncsInTurn` and its check, the tick and sync inputs' `syncsInTurn` field, `KeeperOutput.bindTransport`, and the tickless refusal.
2. **3b: §3.3.** The refinement, the in-step admission and its recording, and `requestJoinSyncTurn`'s route. It touches `SwiftStateTreeTransport`, so its diff spans two modules.
3. **3c: §3.4.** The follow-up requests, the quiescence check, and `KeeperKey.syncBinding` deleted.

The PR body lists the census edits (should 3):
- `KeeperCensusTests.swift`:68, 95, 104, 151–152, 161 and 325–326.
- The `sideStoreDestinations["turnSide.attachedTransport"]` row at :325 describes the stored binding, not a token on each input.
- New rows: `turnSide.attachedSyncsInTurn`, `turnSide.releasedTransport` and `model.syncFollowUpRequests`.
- `actor.transport` and `actor.releasedTransport` move from `.outside(.bindingToken)` to their K2 rows.

### 3.6 A public protocol's behavior change (should 4)

On the core, `LandKeeperTransport.runsSyncPhaseInTurn(of:)` is asked once per attach, by the sender of `.setTransport`. It is no longer asked at each use. This holds for any conformer, and the PR's Public API section records it as a behavior change with no source change.

Two tests re-enter the keeper from the witness:
- InTurnSyncFoldReportTests.swift:194–211
- KeeperTurnSkeletonTests.swift:282–287

They test the keeper's path only. Their re-entry stops firing once commit 4 moves live keepers onto the core. The K2-2 plan's §13.6 gets an item: commit 4 retires them, or moves each to a witness call that still happens per use (the sync queries' named-port read).

## 4. Probes

- **P1, the ports' answers** (§3.1). Done by reading at main 89af141f, not run: a grep of every `runsSyncPhaseInTurn(of:)` in `Sources/`, `Tests/`, `Examples/` and `Benchmarks/`. There are 37 implementations besides the protocol's requirement.
  - **`Sources`, 2:**
    - the adapter (`keeper === self.keeper`, a `let`);
    - the dropping port (`false`, LKT:461), which is exempt from the attach check.
  - **`Tests`, 35:**
    - 28 return a constant `true`.
    - 3 return a constant `false`: TransportRefusalTests:13, LandKeeperReevaluationOutputModeTests:57 and ReevaluationDrainTests:85.
    - One is `keeper === owner` over a fixed owner (TransportRefusalTests:35).
    - Three run code in the witness. InTurnSyncFoldReportTests:194 and KeeperTurnSkeletonTests:282 re-enter the keeper from it, and both still return `true` (§3.6). CDT:761 returns `witnessAnswer`, which `syncStaleTicketAndRefusingWitness` sets before the port's first use (CDT:1996).

  **Result:** no answer changes within one attachment.

P2–P5 were run on 2026-11-28 at main bdaf9d79, on macOS in debug, with `swift test --skip-build --filter …`. They ask how a core arm this plan adds will behave, and those arms don't exist yet. So each probe runs what can run now: the core's own rule (P2), or the keeper's behavior the arm must match (P3–P5). The core half of each becomes the first differential case of its commit, written before the arm.

- **P2, a `.setTransport` sent during a step.** On the keeper, a `setTransport` reached during a body goes through `noteReentry(through: "setTransport")` (LK:571–574, 4138–4158). That counts the violation, closes the gate (`reentryGateForTesting`, LK:2272, 4150), and the land ends. On the core, a send made during a step is queued and steps after it:
  ```
  ✔ Test "7: a send from inside a step is queued and steps after it" passed after 0.001 seconds.
  ```
  (`OrderedChecksTests.sendFromInsideStepIsQueued`: the log is `["hook start", "hook end", "queued"]`, two steps.)

  **So the refusal must sit at the sender, before the send,** and do `noteReentry`'s work on the side (§3.1, sender step 1). Recording a violation alone wouldn't end the land.

  3a's case: a port call inside a core step reaches the attach. On both paths the land ends in that step with `.keeperReentry`, the gate is closed once, and on the core no `.setTransport` steps.
- **P3, the late attach during the drain** (T8):
  ```
  ✔ Test "T8: a transport attached during onLandDestroyed is replaced by the released stand-in and never told the land was destroyed" passed after 0.006 seconds.
  ✔ Test "T8, replay: a re-evaluation keeper's drain runs no destroy handler, and a transport attached during onLandDestroyed is replaced the same way" passed after 0.006 seconds.
  ```
  `attachDuringOnLandDestroyed` (InitAndDrainSegmentTests:733) pins the keeper's order:
  1. An attach during `onLandDestroyed` is applied: the transport is the late one while `destructionFinished` is false.
  2. The drain's end replaces it with `ReleasedLandTransport`, and the late port hears of no destruction.

  **On the core:**
  - The attach is its own `.control` step, between the `.notifyTransport` effect and `.drainFinished`, so `.setTransport`'s step applies it.
  - `.drainFinished`'s step attaches the side's released stand-in.
  - After that, the sender skips the witness, and `.setTransport`'s step attaches the stand-in.

  3a's case runs T8 on the core with the attach held at the effect. The replay variant stays on the keeper until #612.
- **P4, the supersede's clear in the record** (§3.3):
  ```
  ✔ Test "A superseding join with an OnJoin input records its clear with no refused re-entry" with 2 test cases passed after 0.033 seconds.
  ```
  The keeper's path still matches P-K2-2b's golden at main, tick and tickless. That is the stream 3b's adapter and differential cases compare against (§3.3's test seam). The full golden through the core is commit 4's.
- **P5, the writer-drain retry** (§3.4):
  ```
  ✔ Test "writer back-pressure defers the turn's sync: flags and 107 events kept; the drain retry sends them once" passed after 0.023 seconds.
  ```
  (`TransportAdapterInTurnSyncTests`: 13 tests in 2 suites passed with it.) On the keeper, the retry is a staged Task that awaits `waitForWriterDrainForInTurnSync()` and sends the kept events once. The adapter's method awaits `outboundWriter.waitForSyncCycleDrain()`, then polls the test override (TAK:75–79). It needs nothing from the keeper, so it can run as a core effect.

  3c's case applies the same back-pressure on the core. The effect's completion comes back as `.syncFollowUpDue(.writerDrain, ticket)`, and a `.setTransport` between the defer and the completion makes the ticket stale, so no sync-only turn runs.
- **P6, to run before 3c's code: the request's two ends.** A request for `.land` must step its result in a later job, and `endAll` must abandon it through `handleAbandoned(.keyEnded)`. A turn-core test machine checks both:
  1. A request made in a step whose effect returns at once doesn't step in the same segment as its maker.
  2. `waitForQuiescence(.requests)` counts it until its result steps.
  3. `endAll` before the result calls `handleAbandoned` once, and the late result then goes to `handleLateResult`.

  If 1 fails, §3.4's shape changes before any code.

## 5. Tests

- **The differential.** Every case in §3.1–§3.4 runs on both paths with `violations == []` and the quiescence check (§3.4). `refusalReasonsAreNamed` gets the set from §1.
- **3a's cases:**
  - P2's re-entry case and P3's T8 on the core;
  - the attach before, during and after the initialization (§3.1);
  - a tickless server input on both paths, and one while frozen, whose work begins once;
  - the tickless admitted join's drain;
  - `shutdownBatchThatFailsTheLand` enabled.
- **3b's cases:** the three cases of the test seam (§3.3), the syncing joins per shape, and `requestJoinSyncTurn` on both paths.
- **3c's cases:**
  - the twin per follow-up;
  - `.syncTurnNow` consuming a pending follow-up;
  - a follow-up whose binding goes stale;
  - each follow-up at the drain's start.
- **Unchanged on the keeper's path:** `TransportRefusalTests`, `RequestedSyncTurnKeeperTests`, `KeeperPlayerServicesTests` and `SyncStreamLeaveReplayTests`.
- **Each commit's mutant list covers:**
  - the stored read (a step that reads false);
  - the destruction order (the witness asked after the destruction, or the stand-in not attached);
  - the `.control` policy (`.normal` instead);
  - the ticket checks and the slot read;
  - the drafts' place in the record;
  - each `requestedSyncWork` end (dropped, or doubled).

## 6. Rev 3's answers to Review

- **MF1:** §3.1 covers the input, the sender, the step and the released stand-in. The cases for the three attach points against the initialization are in §3.1, and the order against the destruction is in P3.
- **MF2:** §3.1 has the side field, the read-site table and the nil-detach rule.
- **MF3:** §3.2 covers the server input (one work begin) and the admitted join's drain. `requestJoinSyncTurn`'s route is in §3.3.
- **MF4:** §3.3 covers the refinement, the in-step admission and its recording, the safety contract and the test seam.
- **MF5:** §3.4 covers the request shape, the slot read, the writer wait's end, the ends of `requestedSyncWork` and the quiescence check. P6 checks the shape first.
- **Shoulds:**
  1. P2 is rewritten.
  2. §1 states the dependency on #983.
  3. §1 and §3.5 list the census edits and the deletions.
  4. §3.6 records the witness behavior change.
- **Nits:**
  1. The line refs are at 3530a4c2.
  2. `.syncTurnNow` is a named-port read in the table, not a sender-side read.
  3. The count is named `requestedSyncWork` throughout.
- **Q1–Q3:** Q1 is §3.1, Q2 is §3.5 and Q3 is §3.4.

**One question left for Review.** In §3.4, `perform` runs where the core's effects run: the harness now, the owner's executor in commit 4. The writer-drain effect awaits the adapter. Is that acceptable for an effect that can live until the destroy? The alternative is a mailbox post from the adapter when the writer drains, which needs a new port method.

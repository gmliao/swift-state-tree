# K2-2 commit 3: the binding token (#700)

Rev 2 (2026-11-28), plan only: §4's probes run and quoted (rev 1 listed them). It details the K2-2 plan's commit 3 (`2026-11-27-k2-2-cut-over-the-keeper-onto-the-core.md` §3, commit 3; §3.2; §9; §10) and the K2 plan's §4.5 and §18 item 19. Read at main 89af141f. LK = `LandKeeper.swift`, KM = `KeeperMachine.swift`, TS = `KeeperTurnSide.swift`, TA = `TransportAdapter.swift`, TAK = `TransportAdapter+LandKeeperTransport.swift`, CDT = `KeeperCoreDifferentialTests.swift`.

## 1. Goal

Lift every core refusal that waits for the binding token, so that commit 4's precondition holds for this group:
- `KeeperCoreRefusalReason.joinSyncingInTurn` and `.ticklessLandWithTransport` are deleted (KM:347). `refusalReasonsAreNamed` then expects an empty set.
- The three sync follow-ups (`scheduleJoinSyncTurn`, `requestSyncTurnAfterThisTurn`, `retrySyncOnlyTurnAfterWriterDrain`) run on the core as core entries, not as refusals (`refusesSyncFollowUpOnCore`, LK:7233).
- The tickless `.admitServerInput` precondition (KM:953) goes.
- The core-side `actionTableViolations` kinds for requested sync work and pending follow-ups (LK:5459) are unreachable.
- `carriedSyncsInTurn` (KM:314, TS:280), K2-1's stand-in, is deleted.

No public API changes. The admission path is a new package method on the adapter.

## 2. What the code does today

- **The keeper's attach.** `setTransport(_:)` (LK:570) is synchronous. It refuses a re-entry (`bodyDepth != 0`), and on a live keeper it traps when the port answers `runsSyncPhaseInTurn(of: self)` false (`refuseTransportWithoutInTurnPhase`, LK:589). It writes `transport`, `turnSide.attachedTransport` and `model.transportRecordsFolds`. For a non-nil port it then runs `noteTransportBound` (LK:4392), which sets `hasHeldTransport`, clears the bound requester and rebinds `syncBinding`. After the drain's end, it attaches `releasedTransport` instead. Callers: `LandManager` (after its wiring hold), the drain's own `setTransport(nil)` (LK:4932), benchmarks and tests. The adapter never calls it.
- **The core's attach.** The side gets its port once, when `coreTwinForTesting(transport:)` builds it (LK:2221). No input changes it. `KeeperOutput.bindTransport` (KM:456) is declared and never emitted. `.detachTransport`'s flush only logs.
- **The port's answer is fixed per binding.** The adapter's `runsSyncPhaseInTurn(of:)` is `keeper === self.keeper` (TAK:29, TA:118), and `keeper` is a `let` (TA:93). So for a live keeper an attached adapter always answers true, and `setTransport` traps otherwise.
- **How a body reads it on the core.** `side.syncsInTurn(behavior)` (TS:278) uses `carriedSyncsInTurn` when a tick, sync or `.syncTurnNow` step set it. Otherwise it asks the port with `keeperReference.keeper`, which a core's side leaves empty, so the answer is false. Every other step (a join, the input drain, the initialization, `.recordTaken`) would read false where the keeper reads true. That is why the two shapes are refused.

## 3. The design

### 3.1 The binding lives in the model and the side, set by a step

**The proposal.** The binding token is not carried on every input that needs a port. It is stored once, by a `.setTransport` step, and each step reads the current binding:
- `KeeperInput.setTransport(KeeperBindingToken?)`, with `KeeperBindingToken = (port: any LandKeeperTransport, syncsInTurn: Bool)`. The sender reads `syncsInTurn` = `port.runsSyncPhaseInTurn(of: owner)` outside the step, in the same segment as its send, as `.syncTurnNow` does today (§10's row). The harness is the sender in K2-2a's shape; commit 4's facade forwards `setTransport` with the read.
- The step does what `setTransport` does: the re-entry refusal is the facade's (commit 4, `isStepping`); the trap on a live keeper whose port answers false; the post-drain `releasedTransport` arm; then the writes to `side.attachedTransport` and `transportRecordsFolds`, and `noteTransportBound`'s writes for a non-nil port. It also stores the read as `model.bindingSyncsInTurn` (plain).
- `side.syncsInTurn(behavior)` on the core returns `live && attachedTransport != nil && bindingSyncsInTurn`. `carriedSyncsInTurn` and its three writers go.
- The drain's end attaches the released stand-in in `.drainFinished`'s own step, as the keeper's drain calls `setTransport(nil)` after `releasedTransport` (the K2-2 plan's §3.1 row "then `setTransport(nil)` … until commit 3's binding token makes it a step"). A later `.setTransport` attaches the stand-in too (P3).

**Why a stored binding is the keeper's read.** The keeper re-reads `self.transport` and asks the port at each use, after every await. On the core every stage after an await is its own step, and a step that reads the stored binding reads it at that point, after the await. The binding changes only in `.setTransport`'s step, so no step can read a binding that was replaced in between. The port's answer can't change within a binding (§2), so reading it once at the attach gives the same value the keeper would get at each use. This replaces the K2 plan's "the token rides the inputs that need a port" (§4.5). That wording assumed a per-use read, which the adapter's `let keeper` makes unnecessary. **For Review:** this is a change to the K2 plan, stated here so it can be refused.

**A test port whose answer changes.** A test transport could answer `runsSyncPhaseInTurn` differently over time; the adapter can't. Probe P1 lists the test ports and their answers. If one varies within a binding, its tests either keep that land on the keeper's path or send `.setTransport` again.

### 3.2 The tickless land with a transport

With §3.1 in place, the tickless input drain (`inputTurnBody`, LK:8640) reads the same `syncsInTurn` as the keeper, and runs `runTurnOutputs` on the core too. The refusal is deleted.
- The initialization (`initializeTurnBody`, LK:8561) reads the same binding, which covers the survey's possible gap: a tick land's `.initialize` with a transport reads false on the core today.
- The tickless `.admitServerInput`'s kick becomes the resume's shape (KM:843): `debugBeginWork`, a `.serverInputKick` wait on the input's sequence, and `.inputDrainDue` queued behind `.land`. The precondition goes. A query can't queue, so `.admitServerInput` becomes an input on a tickless land; it already answers no error (§10's first row).
- `shutdownBatchThatFailsTheLand` (CDT:2568) is enabled: it was disabled only by this refusal.

### 3.3 The join that syncs in the turn

The keeper's join re-reads the binding at the admission, between segments (`admitJoiningInTurn`, LK:2095), after up to three awaits (the CanJoin resolvers, the kick or the leave wait, the OnJoin resolvers). On the core, `.admit`'s stage is a step, so it reads the current binding there (§3.1), and the `precondition(!syncsInTurn)` at KM:1573 goes.

The admission's port call can't call back into the keeper during a step (K2 §4.5's audit). `admitJoiningSession` reaches `recordSyncStreamClear` on a supersede, which calls the keeper twice: `keeperRecordsSyncStream` (TA:3876) and `submitSyncStream` (TA:4032). Inside a step the second is refused, and the land ends. So this commit adds the package path the K2 plan names:
- `admitJoiningSessionInStep(playerID:clientID:sessionID:joinSequence:recordsSyncStream:) -> (JoinAdmission, [SyncStreamDraft])` on the adapter (package, in `TransportAdapter+LandKeeperTransport.swift`), and on `LandKeeperTransport` as a package requirement with a default that calls `admitJoiningSession` and returns no drafts (test ports).
- It runs the same admission, with the supersede's clear built as drafts and returned, not submitted. The flag is passed in, so the adapter doesn't ask the keeper.
- The core's `.admit` step records the returned drafts at the admission's place, through the side's sync-stream recording, so the clear keeps its order in the record.
- The keeper's own path keeps `admitJoiningSession` until K2-3 deletes that path.

`SyncStreamLeaveReplayTests.supersedingJoinWithOnJoinRecordsItsClear` (tick and tickless) compares the core's stream with P-K2-2b's golden, with the refusal count at 0. The differential gets a syncing-join case per shape (tick and tickless, with and without join resolvers, with and without OnJoin), plus a supersede case, each with `violations == []`.

### 3.4 The three sync follow-ups

Each becomes a core entry that carries the binding's ticket (`syncBinding.current`) and re-checks it in its own step, as the keeper's staged Tasks do (`isCurrent` and `!isDraining`):

| Follow-up | On the keeper | On the core | Its step re-checks |
|---|---|---|---|
| `scheduleJoinSyncTurn` (LK:7241) | a staged Task: sleep `delay`, then `runJoinSyncTurn` (LK:4370) | a core timer keyed `KeeperKey.syncBinding(ticket)` (declared at KM:16, unused today), whose input is `.joinSyncTurnDue(ticket)` | the ticket, `!isDraining`, `hasJoinsAwaitingSync`, `acceptsSyncTurn` |
| `requestSyncTurnAfterThisTurn` (LK:7172) | `pendingSyncTurnAfterTurn` on the side, and a staged Task that runs `runPendingSyncTurnAfterTurn` (LK:4467) | the same side field, and `.syncTurnAfterTurn(ticket)` queued behind `.land`. `syncTurnNow`'s consumption of a pending follow-up (LK:4458) reads the same field | the ticket and the pending entry's port |
| `retrySyncOnlyTurnAfterWriterDrain` (LK:7203) | a staged Task: `await transport.waitForWriterDrainForInTurnSync()`, then `runRetriedSyncOnlyTurn` (LK:4361) | an effect that awaits the writer drain off the core, whose result input is `.writerDrained(ticket)` | the ticket, then `runFollowUpSyncOnlyTurn` |

Their counts (`requestedSyncWork`, `joinSyncTurnsScheduledForTesting`, `requestedSyncTurnsForTesting`) stay in the model, and the work count ends in the step that runs or drops the follow-up. `refusesSyncFollowUpOnCore` and its three call sites go. `syncFollowUpsAreRefusedOnTheCore` becomes a twin case per follow-up and turn kind, comparing the two paths' counts and the sync-only turn that follows. Their redesign stays K3's (K2 §18 item 19).

### 3.5 Slicing

One PR per subsection, in order, each with its differential cases and the census rows it moves:
1. **3a: §3.1 and §3.2.** `.setTransport` as a step, the stored read, `carriedSyncsInTurn` removed, the tickless refusal and the server-input precondition lifted. The census moves `turnSide.attachedTransport` and `actor.transport` from `.outside(.bindingToken)` to their K2 rows.
2. **3b: §3.3.** The syncing join and the package admission path. It touches `SwiftStateTreeTransport`, so its diff is in two modules.
3. **3c: §3.4.** The three follow-ups.

3a has to come first, because 3b and 3c read the stored binding. 3b and 3c are independent of each other.

## 4. Probes

- **P1, the ports' answers** (§3.1). **Done by reading** (2026-11-28, main 89af141f; a grep of every `runsSyncPhaseInTurn(of:)` in `Sources/`, `Tests/`, `Examples/` and `Benchmarks/`, not run). 37 implementations besides the protocol's requirement:
  - `Sources`: the adapter (`keeper === self.keeper`, a `let`) and the dropping port (`false`, LandKeeperTransport.swift:461, exempt from the attach check).
  - `Tests`, 35: 28 return a constant `true`, 3 a constant `false` (TransportRefusalTests:13, LandKeeperReevaluationOutputModeTests:57, ReevaluationDrainTests:85), one is `keeper === owner` over a fixed owner (TransportRefusalTests:35), and three run code (below).
  - Three test ports run code in the witness: InTurnSyncFoldReportTests:194 and KeeperTurnSkeletonTests:282 re-enter the keeper from it, and both still return `true`. CDT:761 returns `witnessAnswer`, which `syncStaleTicketAndRefusingWitness` sets before the port's first use (CDT:1996).

  **Result:** no answer changes within one attachment. One effect to state: on the core the attached port's witness is asked once, by the sender of `.setTransport`, not at every use. The two witness re-entry cases test the keeper's path only and have no core twin, so they stay as they are. The sync queries keep their own per-call read, since each names its own port.
Run 2026-11-28, macOS, debug, at main bdaf9d79 (`swift test --skip-build --filter …`). P2–P5 ask how a core arm this plan adds will behave, and those arms don't exist yet. So each probe runs what can run now: the core's own rule (P2) or the keeper's behavior the arm must match (P3–P5). The core half of each becomes the first differential case of its PR, written before the arm.

- **P2, a `.setTransport` sent during a step.** On the keeper, a `setTransport` reached during a body is refused, and the land ends. On the core, a send made during a step is queued and steps after it:
  ```
  ✔ Test "7: a send from inside a step is queued and steps after it" passed after 0.001 seconds.
  ```
  (`OrderedChecksTests.sendFromInsideStepIsQueued`: the log is `["hook start", "hook end", "queued"]`, two steps.) **So the refusal must sit at the sender**, before the send: commit 4's facade reads `isStepping` (K2 §4.2 (a)). Until then, 3a's harness checks `isStepping` before it sends `.setTransport` and records a trip as a violation, as K2-1 does for the other guarded entries. 3a's case: a port call inside a core step that reaches the attach; both paths end the land, and the core's attach never steps.
- **P3, the late attach during the drain** (T8):
  ```
  ✔ Test "T8: a transport attached during onLandDestroyed is replaced by the released stand-in and never told the land was destroyed" passed after 0.006 seconds.
  ✔ Test "T8, replay: a re-evaluation keeper's drain runs no destroy handler, and a transport attached during onLandDestroyed is replaced the same way" passed after 0.006 seconds.
  ```
  `attachDuringOnLandDestroyed` (InitAndDrainSegmentTests:733) pins the keeper's order: an attach during `onLandDestroyed` is applied (the transport is the late one while `destructionFinished` is false), then the drain's end replaces it with `ReleasedLandTransport`, and the late port hears of no destruction. **On the core:** the attach is its own step, between the `.notifyTransport` effect and `.drainFinished`. So `.setTransport`'s step applies it, and `.drainFinished`'s step attaches the released stand-in (the keeper's `setTransport(nil)` after `releasedTransport`). After `.drainFinished`, `.setTransport` attaches the stand-in, as the keeper's `destructionFinished ? releasedTransport : transport`. 3a's case runs T8 on the core with the attach held at the effect. The replay variant stays on the keeper until #612.
- **P4, the supersede's clear in the record** (§3.3):
  ```
  ✔ Test "A superseding join with an OnJoin input records its clear with no refused re-entry" with 2 test cases passed after 0.033 seconds.
  ```
  The keeper's path still matches P-K2-2b's golden at main, tick and tickless. That is the stream 3b's core case compares against, through `admitJoiningSessionInStep`.
- **P5, the writer-drain retry** (§3.4):
  ```
  ✔ Test "writer back-pressure defers the turn's sync: flags and 107 events kept; the drain retry sends them once" passed after 0.023 seconds.
  ```
  (`TransportAdapterInTurnSyncTests`, 13 tests in 2 suites passed with it.) On the keeper, the retry is a staged Task that awaits `waitForWriterDrainForInTurnSync()` and sends the kept events once. The adapter's method awaits `outboundWriter.waitForSyncCycleDrain()`, then polls the test override (TAK:75), so it needs nothing from the keeper and can run as a core effect. 3c's case: the same back-pressure on the core, with the effect's completion as `.writerDrained(ticket)`, and a `.setTransport` between the defer and the completion making the ticket stale, so no sync-only turn runs.

## 5. Tests

- The differential: per §3.2–§3.4 above, every case on both paths with `violations == []`, plus `refusalReasonsAreNamed` with no reasons left.
- `TransportRefusalTests`, `RequestedSyncTurnKeeperTests`, `KeeperPlayerServicesTests` and `SyncStreamLeaveReplayTests` run unchanged on the keeper's path.
- Each PR's mutant list covers the stored read (a step that reads false), the ticket checks, the drafts' place in the record, and the work count's end.

## 6. Questions for Review

1. §3.1: the stored binding instead of a token on every input that needs a port. The argument is the adapter's `let keeper` plus the step-per-stage shape.
2. §3.5: three PRs (3a, 3b, 3c), or one.
3. §3.4: a core timer for the join sync turn's delay, or a queue entry with the delay as a `run` effect. The timer needs no effect, and a `.setTransport` doesn't end it; the ticket check makes it a no-op.

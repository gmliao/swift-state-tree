# LandKeeper's turns on the turn core (#700)

**Status:** rev 2, plan only. Rev 1 got NOT GO from Review (6 must-fix, 5 should; the direction holds: resolve, apply and sync in the right places, the K1 → K2 strangler, Q1 (c), and the core's recording kept off). Rev 2 answers each point (below), for Review's check and then Code-1's turn-core fit read. No code until Review's GO, and none in a slice whose core gap (§7) is still open.

Code pointers are at main 8e622a20. `LK` is `Sources/SwiftStateTree/Runtime/LandKeeper.swift`, `TA` is `Sources/SwiftStateTreeTransport/TransportAdapter.swift`, `LKT` is `Sources/SwiftStateTree/Runtime/LandKeeperTransport.swift`.

**Rev 2** (Review's plan check of rev 1):
- **MF1, §3.1: G1 narrowed (#758).** The world holds values only: `State`, the admitted queue and entry facts. Each has a snapshot contract where it crosses into resolvers, adapter reads or the sync phase. The references move to narrower homes:
  - `OutputCollector`: the sequence counter goes to the model, events are staged, and handlers get a scoped emitter. AfterFinalize's context gets a decided answer in K7.
  - Recorder: drafts go out as outputs, which `flush` hands to the serial sink in step order.
  - Port: the model holds its binding identity, and the step gets an in-step capability carried by the input or the effect.
  - Services: passed to effects explicitly.

  `flush` gets no world. The world is readable between steps through `core.read`.
- **MF2, §3.3, §3.8: each intake contract kept as it is today.**
  - A tick action without resolvers gets its empty ACK at intake.
  - A tick action with resolvers gets its ACK after the resolvers deliver, before the tick.
  - Tickless actions and tickless client events wait for application, and a client event surfaces its handler's error.
  - A server input replies at intake, frozen or not.
  - A `query` has no reply waiter, so "intake as a query, then await" is gone. A query answers only where today's caller returns at intake; `sendAndWait` is used only where the caller already waits.
- **MF3, §3.7, §8.**
  - The step capability changes `runSyncPhaseInTurn`, a requirement of the public `LandKeeperTransport`: a public break, listed for the maintainer. `runSettlePhaseInTurn` is on the package `LandKeeperSettlePort`, so its change is package-level.
  - The audit is redone. The in-step callback is the join-admission clear; the initial-sync and disconnect records are entries outside a step.
  - Adapter reads go through `core.read`, not a query.
  - The not-in-step assertion is only on synchronous step entries, never on `send`.
- **MF4, §3.2, §3.4: a fresh key per lifetime.** `.syncBinding(BindingID)`, `.entry(PlayerID, EntryID)`, `.freeze(FreezeID)`.
  - Action jobs' requests go under their entry's key, so ending the entry closes them.
  - A caller's cancellation reaches an admitted job through a `.cancelJob` input that cancels its request. It does not use `.cancelsCall`, which leaves a stepped call running.
- **MF5, §5: barriers and the clock.**
  - K2 needs a production `TurnClock` (`TurnCore.init` takes one), so #759 is narrowed to the minimal clock and blocks K2. The timer migration (old K8) is #762.
  - K2 keeps today's entry barriers for initialization and the freeze: `run` can't hold, and nothing in the core holds intake for a freeze. K5 replaces the initialization barrier with a request hold. The freeze barrier needs a core operation (G9) or stays, decided before K7.
- **MF6, §3.10: the type layout.**
  - The public `LandKeeper<State>` is a facade over one of two owners fixed at init: a package `LiveLandTurns<State>: TurnActor` on the shared executor, or a replay owner with no core.
  - The invariant "replay never steps a core" is pinned by ownership: the replay owner has no core field.
  - A replay keeper can have a transport (`.transportAndSink`), and the invariant doesn't depend on it not having one.
- **Shoulds.**
  - Record order is kept by the serial sink taking drafts in step order. A waiter's reply is sent from the record request's completion step, and its abandonment replies `landClosed`. `reply(after:)` isn't used, because it publishes the staged success on abandonment too.
  - K4: the first applied failure is terminal. The last checkpoint comes before the synchronous port publishes anything.
  - K3: the writer gate returns `nil`, so a stale drain never steps.
  - Destroy handlers launch the next request from the previous one's completion.
  - A/B cells: K2's full A/B adds tick actions with and without resolvers and tickless events; K3 gets a host cell for join and kept-event churn. §3.8's budget is measured, not assumed from read1.
  - G3 (#760) is a verification gap until a cross-module generic check shows a compiler problem.
- **Q3 decided (Review): K8 leaves #700** and becomes #762. The driver Tasks only send typed inputs. K9 doesn't wait for K8. K2 keeps the next-tick deadline for the fold and rejects stale wakes after a stop.
- **Q5 decided (Review): the latch test is retired**, with three existing tests named as acceptance coverage and one new test for a case the migration creates (§6.1).
- **New: Q7, §3.1, the shared RNG.** `DeterministicRngService` is a locked class in `services`, drawn by handlers inside steps and reachable by resolvers off the actor. A resolver that draws advances the live RNG, but replay doesn't run resolvers. That looks like a replay divergence. It is not reproduced yet: a finding to confirm and file.

## 1. Goal and scope

#700 moves `LandKeeper`'s turns onto `TurnCore`. Keeper inputs become machine inputs, and work outside turns becomes keyed requests whose results come back as inputs. Each CLAUDE.md reentrancy exception that names the keeper either ends on that model, or is stated as staying with its own issue.

**In scope.**
- Live keepers (`mode == .live`): every entry and every turn kind, the sync follow-ups, the failure mailbox, the action/join/leave/initialize/destroy resolvers, the debug freeze and the land-stop drain.
- The #695 rebind and teardown tests, as acceptance tests (§6.1).
- The CLAUDE.md reentrancy section, updated in the slice that ends each exception.

**Out of scope.**
- **Replay** (#612, parked by the maintainer; #550 is folded into it). Re-evaluation keepers keep today's non-turn path and share the turn bodies (§3.10). #745 and #756 bind #612, not #700 (§3.10).
- **The tick and sync loops as core timers.** That was rev 1's K8, and is now #762 (Q3, §3.9).
- The reevaluation monitor land's tick reading the runner service (#387 PR 2): a user handler, not keeper code.
- #744, #752, and the adapter's B-slices (#546 B1–B6).

**Prerequisites.**

| Prerequisite | State on 2026-11-22 |
|---|---|
| #546 L2 slices (L2a–L2d-3) | merged; L2d-3 is #746 |
| Coalesced follow-ups and the quiescence wait (#702) | merged as #719 |
| One continuation job (#723) | merged as #734 |
| The post lane, now the mailbox (#725) | merged as #738. Names: `Mail`, `post`, `takeMail`, `handleMail`, `TurnMailbox` |
| Lifecycle handler shapes (#593) | merged as #751. The join and resolver items are open; #700 takes them (K5, K6) |
| Core gaps (§7) | G1 #758 (narrowed) and G2 #759 (narrowed to the minimal clock) block K2. G3 #760 is checked before K2's A/B is read. G9 and G10 are candidates, decided before K7 and K5 |

## 2. The keeper today, in short

- **No turn core.** LK doesn't import `SwiftStateTurns`. LK:768–774 calls the three sync follow-up slots "TurnCore's request-per-key shape (#700)… kept by hand".
- **A turn is a synchronous actor function.** `runTickTurn` LK:4679, `runInputTurn` LK:5675, `runSyncOnlyTurn` LK:5056 and `settleTurn` LK:1629 have no `await` between apply and outputs.
  - Every live keeper routes through them (`routesThroughTurn`, LK:735).
  - The sync phase runs in the turn when the port shares the keeper's executor (`syncsInTurn`, LK:742).
  - The adapter adopts the keeper's executor (TA:105) and calls back with `assumeIsolated`.
- **One input queue.** `pendingItems` LK:372 holds actions, client events, lifecycle items, server inputs, the shutdown and the land failure. Everything applies through `applyInputs` LK:3917.
- **Work outside turns is a `Task` that calls an actor method, which re-checks by hand.**
  - Action jobs: LK:2289 starts them, and LK:2336 completes them through `validateDelivery` LK:2211.
  - Join (LK:1866–2057) writes `players` between awaits.
  - Leave (LK:2619–2741) writes `players` before the OnLeave await.
  - Initialize: the init's eager `Task` (LK:1073), then `performInitialization` (LK:1252).
  - Destroy handlers: LK:5986.
  - The three sync follow-ups: LK:5089, LK:5117, LK:5270.
  - The freeze loop LK:1531 and the drain LK:5896.
- **Waiters are continuations.**
  - The tickless turn waiters (`awaitInputTurn` LK:5603) are resumed after the record (`resumeInputTurnWaiters` LK:5728).
  - `awaitActionResult` LK:2468, the freeze waiters, and `shutdownTurnWaiters` LK:5555.
- **Hand-rolled core features:**
  - `GenerationTable` for the sync binding (LK:5147);
  - `EpochCounter` for entry generations (LK:360);
  - `SingleFlight` for `forceShutdown` (LK:2774);
  - the requested-sync-work counter and its waiters (LK:5304–5357);
  - `LandFailureMailbox` (#732).
- **References reached from turns:**
  - the `OutputCollector` class, captured by every `LandContext` (LK:396, LK:3335);
  - the recorder, whose order is reserved synchronously by `ReevaluationSubmissionTracker` (ReevaluationRecorderService.swift:17; `enqueueRecorderSubmission` LK:4977);
  - the port;
  - `services`, including `DeterministicRngService`, a locked class (DeterministicRngService.swift:9).

## 3. Design

### 3.1 What the core holds (MF1; G1 #758, narrowed; Q2, Q7)

`TurnCore.init` requires `M: PlainData`. Rev 1 proposed an untyped world. Review: that is an escape hatch, because a step-scoped `_modify` controls the slot but not references copied out of it, and rev 1 also lent it to `flush`. Rev 2 keeps the world to **values**, and gives each reference a narrower home.

**The model (`KeeperModel`, `@PlainData`, the machine's state).** Every value the core's rules don't need help with:
- counters: `nextTickId`, `lastCommittedTickId`, the input sequence counter (today in `OutputCollector`), the pass ordinal, `BindingID`, `EntryID`, `FreezeID`;
- flags: `isDraining`, `shutdownRequested`, `didInitialize`, `inTurnSyncDue`, `pendingFold`, the terminal failure;
- the next tick deadline and the loop epoch (§3.9);
- the pending queue's order index;
- membership ids, and each entry's `EntryID`;
- action-job bookkeeping: sequence, the caller's `InputID`, the job's `RequestID`;
- the freeze generation and held counts;
- the follow-up binding marks;
- in-flight work counts.

**The world (G1, #758 narrowed): non-plain values, owned by the core, lent only to steps and to `core.read`.**

| Value | What it is | Where it crosses out | Snapshot contract |
|---|---|---|---|
| `State` | the land's state tree | resolvers (`ResolverContext.currentState`), adapter reads (`currentStateLocated`), the in-turn sync phase | A copy taken in the step, or a `borrowing` read in `core.read` and the sync phase. Value semantics are checked at registration by `SyncValueSemantics.validate` (#464; SyncRegistration.swift:89). Its documented exception is unchanged from today: an `@Internal` field may hold a class, and a resolver's snapshot shares it, as it does now |
| the admitted queue | pending items with their `AnyCodable` payloads | resolvers (the action payload), the record draft | copied into the effect or draft in the step |
| entry facts | each player's `PlayerSession` without `services` (ids, device, metadata) | join and leave resolvers, adapter reads | copied in the step. `services` comes from `LandConfig` where a context is built |

- **What the macro can't check is a documented rule:** world values are values. `State`'s is checked at registration. The payloads are decoded values. Entry facts lose their one reference (`services`).
- **`flush` gets no world.** Outputs carry what `flush` needs.
- **`core.read` lends the world read-only between steps,** as it lends the machine. #758's requirements are updated to say so.

**References: each to a narrower home.**

| Today | Rev 2 home | Slice |
|---|---|---|
| `OutputCollector` (LK:396), captured by every `LandContext` | The sequence counter goes to the model. A turn's events are staged in the step and reach `turn.emit` after its last checkpoint (§3.6). Handlers get a scoped emitter, a non-escaping value built per step over the staged buffer, so no context keeps a reference past its step. **AfterFinalize** (LK:5943–5951) gets the live context today, after the drain. K7 first pins today's behaviour of an emit there with a test, then gives it a context whose emit is answered as decided: dropped and counted, since outputs are closed by then. Its handler is async, so it runs as an effect | K2 (counter, staging, emitter); K7 (AfterFinalize) |
| Recorder | A turn's record draft is an output. `flush` hands drafts to the recorder's serial sink in step order. That order is the one `ReevaluationSubmissionTracker` reserves synchronously today: `flush` runs synchronously after each step, before the next. A caller that waits for the record (§3.4) waits on a request that completes when the sink has taken its draft | K2 |
| Port (`LandKeeperTransport`) | The model holds the binding's `BindingID` (its identity and generation). The step reaches the port through an **in-step capability** that arrives with the step's input or effect, tagged with its `BindingID`. The keeper's entry attaches the current port. A follow-up's gate effect carries it (#702 §5). The step uses it only if the tag is current. The actor keeps the port for attaching, written only by the `.bind` step's output | K2 |
| `services` | A `LandConfig` `let`. Handlers in a step get them through the context built in the step. Effects get them explicitly in the effect value | K2 |

**Q7 (maintainer; a finding): the shared RNG.**
- **What it is.** `DeterministicRngService` is a locked, mutable class in `services`. Handlers draw from it inside steps. Resolvers get `services` too (`ResolverContext.services`, ResolverContext.swift:95), so a resolver can draw from it off the actor, at a point the step order doesn't fix.
- **Why it matters.** Replay doesn't run resolvers; it uses their recorded outputs. A live resolver's draw would advance the RNG with no counterpart in replay, so every later handler draw differs.
- **Status.** Not yet reproduced: Code-2 confirms it with a test (a resolver that draws, then replay) and files it if it fails.
- **Direction.** The RNG state moves into the model as plain data, and handlers draw through the step. Resolvers get `services` without the RNG, or a seed of their own recorded with their output. That is decided in the issue, not in #700.
- **#700's part.** K1's census lists the RNG as a reference reached from steps. K2 doesn't change it.

**Q2 (maintainer):** the narrowed world above, or `@PlainData` on every land `State` (a public break)? `@PlainData` would check `State` at compile time. It wouldn't cover the payloads or entry facts, so the world is needed either way. **Recommended: the narrowed world.** A probe of `State: PlainData` can be its own issue.

**K1's census:** every stored field of `LandKeeper`, and its home. The homes are the model, the world, `LandConfig`, the in-step capability, an output, or the K2–K7 replacement list (Tasks and continuations, §3.4, §4). A field that fits nowhere is a finding for Review.

### 3.2 Keys: a fresh key per lifetime (MF4)

`Turn.start`'s rule (Turn.swift:47–51): an input that arrives while a key isn't live steps under the next generation, so use a fresh key per binding. Every key that ends and comes back is therefore keyed by an id from the model.

| Key | Lifetime | What it scopes |
|---|---|---|
| `.land` | started at init, `endAll` at the end of the drain | record-wait requests, the drain's destroy-handler requests |
| `.initialization` | started once at init, ended when initialization finishes or fails; never restarted | the OnInitialize resolver request (K5), and the inputs held behind it (K5) |
| `.entry(PlayerID, EntryID)` | started on join with a new `EntryID`; a rejoin ends the old key and starts a new one; ended on leave | that entry's resolvers (CanJoin, OnJoin, OnLeave) **and its action jobs' requests**. Ending the entry closes them all; this replaces `cancelActionJobs(ofEntryGeneration:)` LK:2500 |
| `.syncBinding(BindingID)` | `setTransport(port)` ends the old binding's key and starts one with a new `BindingID`; `setTransport(nil)` ends it; the teardown is `endAll` | the follow-up slots `.drainRetry`, `.joinSync`, `.afterTurn` (§3.5) |
| `.freeze(FreezeID)` | started by each `debugFreeze` with a new id; ended by resume, shutdown or timeout | the freeze's timeout timer and its settle request (K7) |

A result for a key that has ended is handled by the core: abandonment, or `handleLateResult`. An outside input that targets a binding or an entry carries its id. The handler compares the id with the model's, so a stale one is refused in the step and never reaches a newer generation.

**A caller's cancellation of an admitted job (MF4).**
- **Today.** `awaitActionResult`'s cancellation handler cancels the job (LK:2491, `cancelActionJob` LK:2515), and its resolver task is cancelled.
- **Why not `.cancelsCall`.** It withdraws a call still queued; one that stepped goes on, and only its caller stops waiting.
- **On the core.** The entry calls `sendAndWait(…, .ignoresCancel)` inside `withTaskCancellationHandler`. The `onCancel` hops to the actor and sends `.cancelJob(seq, InputID)`. The step calls `turn.cancel(request)`, and the job's abandonment replies `CancellationError`. That is the hop today's code makes, with its result now an input.
- **G10 (a candidate core issue).** A cancellation delivered to the machine for a call that already stepped would remove that hop. It is decided before K5, and K2 uses the hop.

### 3.3 Inputs: each entry keeps its contract (MF2)

A `query` is a synchronous step whose answer returns at once. It can't register a reply waiter: `Turn.reply` answers only a `sendAndWait`'s `InputID`. So a query is used only where today's caller returns at intake. `sendAndWait` is used only where today's caller already waits for application.

| Entry | Today's contract | Machine input | Reply |
|---|---|---|---|
| Action, tick land, no resolvers (`handleActionEnvelope` LK:2864) | empty ACK at intake (LK:3049–3051) | `query(.admitAction)` | the answer: `.completed(empty)`, or the refusal |
| Action, tick land, with resolvers | ACK after the resolvers deliver, before the tick | `sendAndWait(.action, .ignoresCancel)`, with §3.2's cancellation | from the `.actionResolved` step, at delivery, not from the tick |
| Action, tickless land | waits for the applying turn, then its response (LK:3047) | `sendAndWait(.action)` | from the applying turn's record-wait completion (§3.4) |
| Client event, tick land (`handleClientEvent` LK:3083) | returns after intake | `query(.admitClientEvent)` | the answer: accepted, or the thrown refusal |
| Client event, tickless land | waits for application, and throws the handler's error (LK:3166–3178) | `sendAndWait(.clientEvent)` | from the applying turn's record-wait completion: success, or the handler's error |
| Server input from outside (`submitServerInput` LK:3198) | `.accepted`/`.refused` at intake. While frozen, accepted at once and held (LK:3250) | `query(.admitServerInput)` | the answer |
| Server input from inside a handler (`serverInputSubmitter` LK:3308) | the same call, made inside a turn | none: the handler's own step appends to the queue through the world. A query from inside a step would trap | the outcome, returned synchronously in the step |
| Join (`joinReportingAdmission` LK:1866) | waits for admission | `sendAndWait(.join)` | from the admission step (K2: the last of today's segments; K6: the one validate-and-apply step) |
| Leave (LK:2619) | waits for the leave | `sendAndWait(.leave)` | from the leave's last step |
| `stepTickOnce` LK:3456 | waits for the tick | `sendAndWait(.tickDue(...))` | from the tick's record-wait completion |
| Tick and sync loop wakes | Tasks calling actor methods | `send(.tickDue(scheduled, loopEpoch))`, `send(.syncDue(scheduled, loopEpoch))` (§3.9) | — |
| `syncTurnNow` LK:5249, `syncTurnTicket` LK:5235, `settleTurn` LK:1629 (synchronous, from the adapter outside a keeper step) | a synchronous answer | `query(.syncTurnNow(capability, reason, ticket))`, `query(.syncTurnTicket)`, `query(.settle(capability, fence))` | the answer |
| `setTransport` LK:484 | synchronous | `send(.bind(port?))`, a control input | — |
| `debugFreeze` LK:1531 / `debugResume` LK:1562 | waits / synchronous | `sendAndWait(.freeze(FreezeID, timeout))` / `send(.resume)` | freeze: from the settle step or the timeout (K7) |
| `forceShutdown` LK:2761 | waits for the drain | `sendAndWait(.shutdown)`, control | after the drain's last step. A second call joins the reply list, replacing `SingleFlight` |
| `notePendingFailure` LK:575 (nonisolated) | set-once box | mail `.landFailure(f)` (K4, §3.6) | — |

**Results that come back as inputs:** `.actionResolved`, `.joinResolved`, `.leaveResolved`, `.initializeResolved`, `.destroyHandlerResolved`, `.recordTaken`, `.drainFinished`, `.cancelJob`.

#### 3.3.1 Barriers: kept at the entries in K2 (MF5)

- **Initialization.** Today every entry awaits `ensureInitialized` before intake.
  - K2 keeps that barrier at the entry. The entry reads `didInitialize` through `core.read`, which costs no step. Before initialization finishes, it waits on `sendAndWait(.awaitInitialized)`, replied by the initialize step.
  - K5 makes initialization a request under `.initialization`. Intake then holds on it with `Hold.untilRequestCloses`, and the entry barrier is deleted.
  - `run` (K2's resolver mechanism) can't hold, which is why K2 keeps the barrier.
- **The freeze.** Tickless intake while frozen awaits `debugWaitWhileFrozen` LK:1683 today. K2 keeps that barrier at the entry: it reads the frozen flag through `core.read` and waits on `sendAndWait(.awaitResume)` when frozen.
  - The core has no hold released by a step. Holds end with a request (`untilRequestCloses`) or a worker (`untilWorkerReturns`), and the freeze's timeout timer can't hold intake on its own.
  - So K7 either uses a new core operation, **G9** (a hold that a step releases), or keeps the entry barrier and documents it as allowed. That is decided before K7, and G9 is filed if K7 takes it.
- **Tick lands.** A tick land keeps today's rule: inputs queue and a frozen tick doesn't run.

#### 3.3.2 Membership facts kept (#612's rev-3 and rev-4 reviews)

The line numbers below are from those reviews, at an older commit; K1 re-points them. Each fact is a test that K2 keeps green:
- `players` changes before the resolvers' await (then LK:1576/1798/2494); on the core, in a step.
- In-boundary clears belong to their own boundary: the shutdown (then LK:3619) and `failLand` (then LK:5285).
- A reconnect with no handler still changes `players`.
- A join that didn't complete is rolled back (then LK:1628/1856/5586).
- Today's tick-turn order: W1, inputs, W2, the handler, the committed tick and hash, the port, the record draft. Also the failed-input-prefix path.
- Waiters resume after the record is taken (#612 rev-2 MF2b): §3.4.
- The live hash gate stays `mode == .live && reevaluationRecorder != nil && usesInTurnSync`.

### 3.4 Work outside turns as keyed requests

| Work | Today | On the core | Slice |
|---|---|---|---|
| Action resolvers | a `Task` per job; `completeAction` re-checks the job, the entry generation and the caller's cancellation | `turn.request(.resolveAction(snapshot, services), for: .entry(pid, eid))`, from the intake step. The completion `.actionResolved` delivers. A closed request runs `handleAbandoned`, which replies as `validateDelivery` does today: `landClosed` when the entry ended or the land is closing, `CancellationError` after `.cancelJob` | K2: `run` with today's checks in the handler; K5: `request` |
| CanJoin / OnJoin / OnLeave resolvers | awaited inside `join` and `leave` | requests under `.entry(pid, eid)`. A rejoin ends the old key and closes them, replacing the generation checks at LK:2016 and LK:5853 | K2: `run`; K6: `request` |
| The old session's kick on a duplicate login | `try await leave(...)` LK:1937 | in the join's step: the membership change, then the old entry's OnLeave as a request under the old key (#588) | K6 |
| OnInitialize resolvers | awaited in `performInitialization` LK:1297, then a direct write LK:1339 | a request under `.initialization`. `.initializeResolved` validates and applies (#593's two phases) in its step | K5 |
| Destroy handlers | awaited in order in the drain | One request at a time under `.land`. Each `.destroyHandlerResolved` step launches the next handler's request. `queue(behind:)` orders inputs, not effects, so it can't order them | K7 |
| Waiting for the record | `await submitTurnRecord` LK:5019, then the turn waiters resume | The step outputs the draft (§3.1), and requests `.awaitRecordTaken(ticket)` under `.land`. The waiters' replies are sent from its completion step `.recordTaken`, and its abandonment (only at `endAll`) replies `landClosed`. `reply(after:)` isn't used: it publishes the staged reply on abandonment too, which would tell a caller its input was recorded when it wasn't | K2 |
| Sync follow-ups (three slots) | Tasks with binding marks | #702 plan §5 (§3.5) | K3 |
| The in-turn sync phase | already synchronous | unchanged, called from the step through the in-step capability (§3.7) | K2 |

- **Resolvers see no keeper data.** A resolver gets `ResolverContext`, which holds a state snapshot and `services`, and has no emit or sync request (ResolverContext.swift:37–95). As an off-actor request, it reaches no keeper data apart from Q7's RNG.
- **Cost.** A core `request` costs about 13.1k instructions over direct (#624). Actions with resolvers already create a `Task` and hop twice today. Actions without resolvers make no request. K5's A/B decides. A regression there is fixed in the core (#621 item 3), not with a keeper shortcut.

### 3.5 Sync follow-ups: #702 plan §5, with fresh binding keys

- **Keys.** #702 §5 is adopted, with the binding key per bind: `.syncBinding(BindingID)` (§3.2).
- **Slots.**
  - `.drainRetry` uses `.afterWork(.waitForWriterDrain(capability), deadline:)`;
  - `.joinSync` and `.afterTurn` use `.afterBatch`.
- **The writer gate's result is `nil`.** Its `perform` returns `nil`: its only job is to make the retry due. So no `.writerDrained` input exists, and a stale drain never steps. The follow-up step does the retry, with #702's checks in order: `mode == .live`, `failure == nil`, `!isDraining`, then the port's `runsSyncPhaseInTurn(of:)`. The join-sync step re-checks `transportHasJoinsAwaitingSync`.
- **`syncTurnNow`'s order** is kept: accept the capability and its `BindingID`, then consume, then run the phase. A stale ticket returns `.skipped` and consumes nothing.
- **Counters** are placed as #702 §5.4 says. `.keptEvents` moves to the machine.
- **Waits.** `waitForRequestedSyncTurnsForTesting` becomes `waitForQuiescence(.followUps, of: .syncBinding(current))`, and the requested-sync-work counter and waiters (LK:5304–5357) are deleted.
- **The intended order change.** Join-sync and after-turn follow-ups armed by one commit now run in arm order. Today they are two Tasks. K3's PR body states this, and the harness row `join-during-writer-backlog` shows whether any golden moves.

### 3.6 The failure mail and staging: #725 plan §4

- **The mailbox.** `LandFailureMailbox` becomes the core's mailbox: `Mail = LandReport`, capacity 1. `notePendingFailure` becomes `post(.landFailure(f))`.
- **Capacity 1 isn't set-once.** It is full until taken, and a post to a full mailbox is refused and counted. So the **first applied failure is terminal**: the step that takes it sets the model's failure, and every later report, taken or refused, leaves it unchanged. A test posts twice around a take and checks that the first failure is the one recorded.
- **Checkpoints.** Each of today's reads becomes a `turn.takeMail()` checkpoint (post-lane plan §4.1):

| Turn kind | Checkpoints |
|---|---|
| any | the driver's pre-step check |
| initialize | after `finishApply`, even with no `OnInitialize` |
| tick | after apply and the handler, then before `runTurnOutputs` |
| tickless input | after `takePassOrdinal`, before `if failure != nil`, and before the outputs |
| sync-only | the start of the step |
| settle | the start of the step; returns `.failed(f)` |

- **Staging.** A turn's events and replies are staged in the step. The last checkpoint comes **before anything publishes**: before `turn.emit` and `turn.reply`, and before the synchronous port call that sends frames (`runSyncPhaseInTurn` publishes directly). #716's "no `emit` before `finishApply`" alone doesn't cover the port. A failure found at a checkpoint drops what is staged, and the callers get `landClosed`. A post that lands after the last checkpoint is taken before the next step.
- **Removed:** `submitLandFailure`, `.failureSubmit`, and the adapter's awaited submit in `failOutsideTurn` (TA:5656). The adapter keeps `post` and the gate close.
- **The record's shape change** (post-lane §4.2) goes in K4's PR body, pinned by a test: two inputs queued, a post, then the turn. The record holds the failure first, and both inputs are refused.
- **The core's recording stays off.** `onMailTaken` is never set (§3.10).

### 3.7 Calls into the keeper during its own step (MF3)

The in-turn sync phase calls the port synchronously: `runSyncPhaseInTurn` (LKT:180), a requirement of the **public** protocol `LandKeeperTransport` (LKT:41), and `runSettlePhaseInTurn` (LKT:309), a requirement of the **package** protocol `LandKeeperSettlePort` (LKT:305).

| Adapter call into the keeper | Where it runs | On the core |
|---|---|---|
| The join-admission clear: `recordSyncStreamClear` (TA:3951) → `submitSyncStream` via `assumeIsolated` (TA:3956), with `keeperRecordsSyncStream` (TA:3800) | **inside keeper work**: the port's in-turn join admission while the keeper applies a join | through the step's capability: the record draft goes into the step's staged drafts. Calling the actor would step the core inside a step, which traps |
| `recordSyncStream` (TA:3825) from the initial sync | outside a keeper step | an entry: `send(.syncStreamDraft(...))`, which steps at once when idle and keeps its order with the turns |
| `recordSyncStreamClear(outsideTurn: true)` from a disconnect | outside a keeper step | the same entry |
| `syncTurnNow`, `syncTurnTicket` (TA:3128, 3181, 3197, 3201, 3489, 3494, 5099, 6374), `settleTurn` (TA:6223) | outside a keeper step (each is the adapter's own path) | `query` (§3.3). K2 lists each site, with the reason it can't run inside a keeper step |
| Reads: `entrySession` (TA:1458), `currentStateLocated` (TA:5212), `isLive`, `isDraining` and the like | outside a keeper step | **`core.read`** on the model or the world, which is a borrow and not a step. A query is a step with a mailbox take and an ordinal |
| `joinReportingAdmission`, `leave`, `handleClientEvent`, `submitAction`/`awaitActionResult`, `requestJoinSyncTurn`, `debugFreeze`, `debugResume`, `notePendingFailure` | outside a keeper step | the entries in §3.3 |

**The public break (§8).** The step capability changes `runSyncPhaseInTurn`'s signature: it gains a parameter, a non-escaping in-step capability through which the recorder calls go. Every conformer changes: `TransportAdapter`, the test fakes, and any out-of-repo conformer. It is listed for the maintainer. `runSettlePhaseInTurn` gains the same parameter, as a package change.

**The debug check is on synchronous step entries only:** `query`, and the keeper's synchronous entries that step. A call to one of them from inside a keeper step traps with the entry's name. `send` from inside a step legally queues, so it is never asserted.

### 3.8 The per-message path: cost

Client events and actions are per-message, and #546's decision budgets about +100 instructions per message for the core.
- read1's 13 instructions over direct (#624) measure a `core.read`. They don't measure a query step, which takes the mailbox and an ordinal.
- So the cost of rev 2's query intake (§3.3) is **not established**. K2's full A/B measures it on the cells that carry it: tick actions with and without resolvers, and tickless client events (§5).
- A tick action with resolvers and every tickless input wait today on a continuation. On the core they wait on a reply waiter (`call` is about 2.9k instructions over direct), so one waiter replaces one continuation.
- **If K2's A/B puts the query intake over budget,** the fix is in the core: G5 (#761, a `send` that returns its admission when it steps at once), or a cheaper admission step. It is not a keeper shortcut. Until then, nothing blocks K2.

### 3.9 Ticks and the sync loop (Q3 decided: timers are a follow-up)

- **Drivers.** The loop Tasks (LK:3402–3441, LK:5739) stay as drivers that only send typed inputs:
  - `.tickDue(scheduled, loopEpoch)` and `.syncDue(scheduled, loopEpoch)`;
  - `scheduled` is the instant the driver slept for;
  - `loopEpoch` is the model's, read when the loop was configured.
- **What the steps do.**
  - The `.tickDue` step writes the next tick deadline into the model, which the fold rule reads (LK:787).
  - A wake whose `loopEpoch` isn't current (after a stop or a reconfigure) is rejected in its step.
  - The fold rule moves into the `.syncDue` step.
- **The follow-up issue.** Moving both loops onto core timers needs #753's one sleeper and a `TurnClock` with timers (#759 only gives K2's minimal clock). It has its own timing semantics:
  - the first fire is the phase offset plus one interval;
  - the scheduled instant rides in the input;
  - skip-ahead is the handler's arithmetic.

  It is #762. K9's deletions don't wait for it.

### 3.10 The type layout, and re-evaluation keepers until #612 (MF6, Q1)

A public `LandKeeper<State>` can't conform to `TurnActor` only when `mode == .live`. `TurnActor` and `scripts/lint-turns.sh` require a stored `let core` and a stored `nonisolated let mailbox` (the `let-mailbox` rule). So the live part is its own actor:

```swift
public actor LandKeeper<State: StateNodeProtocol> {          // public facade; its API unchanged
    nonisolated let owner: KeeperOwner<State>                  // fixed at init by mode
    nonisolated public var unownedExecutor: UnownedSerialExecutor { owner.executor }
}
package enum KeeperOwner<State: StateNodeProtocol>: Sendable {
    case live(LiveLandTurns<State>)
    case replay(ReplayLandOwner<State>)
    var executor: UnownedSerialExecutor { … }                  // the live actor's, or the replay executor's
}
package actor LiveLandTurns<State: StateNodeProtocol>: TurnActor {
    let core: TurnCore<KeeperMachine<State>>                   // the model, plus the world (G1)
    nonisolated let mailbox: TurnMailbox<LandReport>           // core.mailbox
    let config: LandConfig<State>
    // perform, flush; nothing else stored but the port for attaching (§3.1)
}
package final class ReplayLandOwner<State: StateNodeProtocol> {  // isolated to the replay executor; no core
    var model: KeeperModel
    var world: LandWorld<State>
    let config: LandConfig<State>
}
```

- **The executor.**
  - On a live keeper, `LandKeeper` adopts `LiveLandTurns`' executor. The adapter adopts the keeper's (TA:105), so all three share one serial executor.
  - The facade forwards with `live.assumeIsolated { … }`: synchronous, no hop.
  - A replay keeper adopts the executor of a small replay actor that runs `ReplayLandOwner`'s path.
  - `LiveLandTurns` is created first in `LandKeeper.init`, so the facade's `let owner` is set without `self`.
  - Code-1 to check this against the core's rules.
- **The turn bodies (K1)** are synchronous functions over `(inout KeeperModel, inout LandWorld<State>, LandConfig<State>, …)`. The live path calls them inside steps. The replay path calls them from `ReplayLandOwner`'s path, which awaits the source between them, as it does today: the CLAUDE.md exception "until #612".
- **The invariant: replay never steps a core,** pinned by ownership: `ReplayLandOwner` has no core field, and the replay path never reaches `LiveLandTurns`. A must-not-compile snippet pins that `ReplayLandOwner` has no `core`. A replay keeper can have a transport (`.transportAndSink`: `flushOutputs` sends to it, LK:692–710). The invariant doesn't depend on it not having one, because that transport is never a sync binding: `routesThroughTurn` and `syncsInTurn` are false for re-evaluation keepers (LK:735, LK:742).
- **Q1 (maintainer)** is rev 1's question. Rev 1 recommended (c), and rev 2 makes it concrete:
  - (a) a core that lends itself mutably while never stepped;
  - (b) replay ticks as core inputs, which is #612's redesign;
  - **(c), recommended**, the layout above.
- **#745 and #756.** Both concern the core's own record and replay. #700 uses neither:
  - live keepers record through the keeper's recorder (§3.1), and `onMailTaken` is never set;
  - replay owns no core.

  So #756's "before any adopter records mail" holds, and #745's limitation never meets a keeper path. Both stay with #612.

## 4. How each CLAUDE.md exception ends

| Exception (CLAUDE.md) | Code today | Ends in | How |
|---|---|---|---|
| Join/leave resolvers | LK:1866–2057, LK:2619–2741 | K2 (steps), K6 (#588) | Membership changes in a step, and resolvers are requests under `.entry(pid, eid)`. A rejoin ends the old key. CanJoin validates and OnJoin applies in one step. The old session's leave is in that step. #548's in-turn variant is a test |
| Freeze drain/settle (#129) | LK:1531–1556 | K7 | `.freeze(FreezeID, timeout)` starts its key, arms the timeout timer and asks for the settle. The caller's reply comes from the settle step or the timer. A newer freeze supersedes the key, so there is no await loop and no hand re-check. The tickless intake barrier: G9 or a documented barrier (§3.3.1) |
| Action-frame bookkeeping after the resolvers (`debugEndWork`, `awaitInputTurn`) | LK:1696, LK:5603 | K2 (the waiter), K5 (`debugEndWork`) | The waiter is a reply (§3.4). In-flight work is the model's count, changed in the intake step and in the result or abandonment step |
| The land-stop drain's post-await bookkeeping (#522) | LK:5896–5964, LK:5970 | K7 | `.drain` captures the land's state in its step: the ticket is `.land`'s generation, #522's "drain finished (ticket)". Destroy handlers run as chained requests. `.drainFinished` does the release in its step, through the captured binding (#698: Q4) |
| `LandFailureMailbox` stands in for the core's mailbox (#732) | LandFailureMailbox.swift, LK:565–575 | K4 | §3.6 |
| Re-evaluation keepers' non-turn replay path (#612) | LK:4254–4553 | **stays** until #612 | §3.10 |
| The reevaluation monitor tick (#387) | ReevaluationMonitorLand.swift:28–70 | **stays** until #387 PR 2 | not keeper code |

Not listed in CLAUDE.md, but of the same class, and these end too:
- OnInitialize resolvers followed by a direct write, and `didInitialize` set after an await (LK:1103–1105): K5.
- The tick land's force shutdown, whose shutdown turn writes `nextTickId` before an awaited record (LK:2796–2799): K2.
- `runTick`'s writes before `runTickTurn`: K2, inside the `.tickDue` step.
- `tearDownAfterFailedInitialization` (LK:1173): K5.

## 5. Slices

Each slice is its own PR to `main`, after Review's GO on this plan.

**Every slice runs:**
- `swift test` on both legs, and `swift test` in `Examples/Demo` and `Examples/GameDemo`;
- E2E in three encodings, plus the game E2E with reevaluation (0 mismatch);
- `swift build -c release` and the release filter on the touched suites;
- must-not-compile;
- one mutant per new rule.

**The differential-harness pass** (adapter differential harness, rev 10; 84 cells, all in-turn since L2c):
- byte comparison in the pinned 6.2.4 image;
- `scripts/differential-gate.sh` with `ran + replaced == listed`, `ran > 0`, `compared == run`, `threw == 0`;
- each difference in `ExpectedDifferences.swift` (exact, one cell, one use) with its cause, classified by `scripts/classify-golden-changes.py`.

**Host A/B tiers** follow the proportional rule:
- **full:** #554's five cells plus `nonsync`, ABBA with 5 pairs; a regression is more than max(0.5 %, 3× spread) on `instructions:u`;
- **small:** 1–2 cells.

A cell this plan needs that doesn't exist yet is added first, in a tool-only commit with a Mac output check, so base and change run the same tool.

| Slice | Content | Needs | Harness: allowed differences | Host A/B |
|---|---|---|---|---|
| **K1** | The storage split and its census (§3.1). Turn bodies become synchronous functions over model, world and config. Every multi-await flow's segments become named synchronous functions. No core, and behavior is unchanged. Replay calls the same bodies | — | none | **small**: the default production cell and `rows-mp` (field access moves into structs, and codegen can move) |
| **K2** | The cut-over. The layout in §3.10. Every live entry is a core entry with its contract (§3.3), and each K1 segment is a step. Each await between segments is a `turn.run` whose result is an input, with today's checks in the handler. Also in K2: fresh keys (§3.2), the record drafts and waits (§3.4), the scoped emitter and the in-step port capability (§3.1, §3.7), entry barriers (§3.3.1), drivers (§3.9). Follow-ups and the failure box work as today | G1 #758, G2 #759 (minimal clock); G3 #760 checked before its A/B is read | none | **full**, plus three cells: tick actions without resolvers, tick actions with resolvers, tickless client events |
| **K3** | Sync follow-ups on the core (§3.5), the writer gate returning `nil`, `waitForQuiescence`. The hand-rolled slots and requested-sync-work waiters are deleted. The #695 acceptance tests are rewritten (§6.1) | K2 | only the arm-order change (§3.5), if a cell shows it | **small**: a host cell with join churn and kept-event follow-up churn |
| **K4** | The failure mail (§3.6): capacity 1 with the first applied failure terminal, checkpoints, staging before the port, the record-shape change. `LandFailureMailbox`, `submitLandFailure` and `.failureSubmit` are deleted | K2 | failure rows' record order, if a cell has a post before queued inputs | **small**: the default cell and `rows-mp`. The mailbox costs every entry (+396 emit, +440 call, post-lane §3.8), and this slice sets the budget left open there |
| **K5** | Resolvers as keyed requests: action jobs under their entry's key (abandonment replaces `validateDelivery`'s checks; `.cancelJob`, or G10 if filed and fixed), OnInitialize under `.initialization` (initialization as a turn; the entry barrier replaced by `Hold.untilRequestCloses`), `debugEndWork` as the model's count | K2; G10 decided | none | **small**: the default cell and the tick-actions-with-resolvers cell |
| **K6** | Join and leave per #588. CanJoin is `validate` with `ValidateContext`, returning a plan; OnJoin is `apply`; both in one step. That step also does the stale-join refusal, `maxPlayers` (reconnection exempt), the duplicate-login kick and the draining guard. One refusal form, a recorded refused join, and #548's tests | K5 | join-refusal rows, if the one refusal form changes their bytes | **small**: K3's join-churn cell |
| **K7** | The freeze (#129) and the land-stop drain (#522) on the core (§4), the destroy handlers chained (§3.4), AfterFinalize's context (§3.1), forceShutdown's `SingleFlight` replaced | K5; G9 decided | none: the `freeze-resume-*` rows stay byte-identical | **none**: debug freeze and teardown are off the measured paths; recorded as a `call` with that reason |
| **K9** | Deletions: the keeper's `GenerationTable`/`EpochCounter`/`SingleFlight` uses, the replaced `HoldPoints` (§6.3), and the dead `.live` arms (`flushOutputs` LK:674–691, `runSyncRequests` LK:718, the recorder branches at LK:3871, 4523, 4540, 1404–1413), each first proven unreachable. CLAUDE.md's reentrancy section is rewritten: the keeper exceptions left are #612, #387, and the freeze barrier if K7 keeps it. It doesn't wait for the timer follow-up | K1–K7 | none | **Mac output check** |

(K8 is no longer a slice: §3.9.)

**Ordering.**
- K1 can start before G1 and G2 land.
- K3, K4 and K5 are independent of one another.
- K6 needs K5's requests.
- K7 needs K5, for chained requests.

**Stop conditions** (#546's decision, applied to the keeper):
- If a slice needs a coordinator-shaped machine API (a query that runs arbitrary keeper code, or a switch at each write), stop and redo the outline.
- If K9's deleted scaffolding is smaller than the machine code K2–K7 added, Review revisits.
- A core gap found mid-slice stops the slice: report it, fix it in the core, then resume (core-gap-fix-core-first).

## 6. Tests

### 6.1 #695's acceptance tests, and the latch test (Q5 decided)

| Test | On main | At #700 |
|---|---|---|
| Rebind with a held retry: `olderBindingsRetryDoesNotBlockTheCurrentOne` (`TransportAdapterRequestedSyncTurnTests.swift`) | yes | K3 rewrites it per #702 plan §5.5 (b)–(d). B's follow-up is `.armed` while A's gate waits. A's late gate return steps nothing, checked with a step counter. B delivers stamp 2 while A's writer is held. Its mutant, a keeper-wide slot, still fails it |
| Teardown with an armed retry: `teardownEndsAnArmedRetry` | yes | K3. Slot quiescence after the teardown, **plus** a separate check that A's gate returned after the teardown (quiescence alone passes with a stranded gate). Its mutant, the writer teardown not releasing its drain waiters, still fails it |
| Latch window: `syncDuringSettleCycleIsLatched` | no | **Retired, nothing to port**: L2b (#712, ef23c7a7) retired it, and L2d deleted the latch slot |

**Acceptance coverage named in its place** (Review, Q5):

| Test | Covers | Slices |
|---|---|---|
| `ordinaryPhaseKeepsTheFrozenDefer` (TransportAdapterDebugFreezeTests:625) | a phase during a freeze keeps the deferral | K2, K7 |
| `freezeIsCheckedBeforeBackPressure` (TransportAdapterRequestedSyncTurnTests:206) | the freeze check comes before back-pressure | K3 |
| `eventKeptBySettleArrivesAfterResume` (TransportAdapterPendingEventsAcrossCyclesTests:653) | an event kept by the settle arrives after the resume | K3, K7 |

**New, for a case the migration creates:** a follow-up armed before a freeze and still due at the settle. The settle step runs, and the follow-up steps after it, once, under its binding. K3 adds it, and K7 keeps it green.

**K3 also adds:**
- #702 plan §5.3's keeper test: a stale lag request with an after-turn follow-up pending leaves it pending, and it steps.
- #695 round 3's known gap: an older binding's retry that is still waiting on its writer, across a teardown that reaches only the new binding's writer. `endAll` closes it, and it doesn't stay counted.

### 6.2 New tests per slice

Tests force interleavings with holds (`HoldPoints`, `TestGate`, a gated `perform`), never timing, and bound every wait (`withinDeadline`, `withinHangBound`).

| Slice | Tests |
|---|---|
| K1 | The census: every stored property of `LandKeeper` has a home (§3.1), checked by `Mirror`, so a new field fails the test until it is placed. The RNG is listed as a reference reached from steps (Q7) |
| K2 | **Each intake contract in §3.3:** the tick ACK without resolvers returns before any tick; the ACK with resolvers returns after delivery and before the tick; a tickless client event's handler error reaches its caller; a server input while frozen returns `.accepted` at once. **Steps:** a query from inside a keeper step traps (debug), and `send` from a step queues. **Waiters:** they resume after the record is taken, with the record request held; an abandoned record wait replies `landClosed`. **Keys:** a stale `BindingID` and a stale `EntryID` are refused in the step. **Barriers:** intake before initialization waits on the barrier. **Shutdown:** the tick land's shutdown applies inside its step. **Loop:** a stale loop wake is rejected. **Replay:** `ReplayLandOwner` has no core (must-not-compile) |
| K3 | §6.1 |
| K4 | Two inputs queued, a post, then the turn (§3.6). Two posts around a take: the first failure is terminal. A failure at the last checkpoint publishes nothing to the port. The S1b "no `emit` before `finishApply`" mutant still fails |
| K5 | A job's caller cancels while its resolver is held: the request is cancelled and the caller gets `CancellationError`. The entry leaves while its job's resolver is held: abandonment, `landClosed`, nothing applied. Initialization's resolver is held while a join arrives: the join holds, then is admitted |
| K6 | #588's checks in one step, each refusing in one form. #548: hold the join's resolver, tear down, release with `.allow`; no membership, slot, joining record or connection generation is left (plus the in-turn variant). A duplicate login's old OnLeave runs as a request under the old key |
| K7 | #129's freeze and resume, interleaved with a deferred writer retry held at the former await. A newer freeze supersedes an older one's settle. A `leave` during the destroy handlers is refused. Destroy handlers run in order, the next launched from the previous completion. `forceShutdown` called twice gives one drain and two replies. AfterFinalize's emit behaves as pinned |

### 6.3 The keeper's hold points

LK:55–82 has 11 points:
- K2 keeps each point where it still exists, now inside a step or a `perform`.
- K5 and K7 move the points that sat between an await and a write into the effect's `perform`: `.actionComplete`, `.join`, `.leave`, `.drainStart`, `.landFailedTeardown`. The interleaving they forced becomes a held completion while other inputs step.
- K4 deletes `.failureSubmit`.
- K9 deletes the points with no user.

Each PR lists the tests whose hold moved.

## 7. Turn-core gaps

Each is reported as a core issue, per core-gap-fix-core-first.

| # | Gap | Tracked | Blocks |
|---|---|---|---|
| G1 | The world (narrowed, §3.1): values only (`State`, the admitted queue, entry facts), lent to steps and to `core.read`, not to `flush` | **#758** (foundation; narrowed in a comment, rev 2) | K2 |
| G2 | A production `TurnClock` over `safeTaskSleep`, minimal: `now` and `sleep(until:)` for `TurnCore.init` | **#759** (foundation; narrowed in a comment, rev 2). The timer migration is #762 | K2 |
| G3 | Step-path specialization for a generic machine instantiated from another module: a verification gap until a check shows a compiler problem | **#760** | reading K2's A/B |
| G4 | One sleeper for all deadlines | #753 (#621 item 2) | #762 |
| G5 | `send` returns `Void` | **#761** (before-release) | nothing; only if K2's A/B puts the query intake over budget (§3.8) |
| G6 | Effect launch and hop cost | #621 item 3 | only if K5's A/B regresses |
| G7 | The waiter table's cost | #621 item 4 | only if K2's A/B regresses on waiting entries |
| G8 | The mailbox's per-entry cost has no budget | post-lane §3.8 open item | K4 sets it |
| G9 | A hold released by a step: the freeze's intake barrier | candidate, not filed | decided before K7; filed if K7 takes it |
| G10 | A caller's cancellation delivered to the machine for a call that already stepped (replaces K2's `.cancelJob` hop) | candidate, not filed | decided before K5 |

Not gaps for #700: the core's input recording, `.cancelsCall` in replay, #745 and #756 (§3.10).

## 8. Public API

- **K2, `LandKeeperTransport` (public): a break, for the maintainer.**
  - `runSyncPhaseInTurn` (LKT:180) gains a non-escaping in-step capability parameter for the recorder calls (§3.7). (`runSettlePhaseInTurn`, LKT:309, is on the package `LandKeeperSettlePort` and gains it as a package change.)
  - Every conformer changes: `TransportAdapter`, the test fakes, and any out-of-repo conformer.
  - Options for the maintainer: the break as is, with no deprecation step, as #593 did; or a defaulted overload that traps, to point a missed conformer at the change.
  - **Recommended:** the break as is. The protocol is the adapter's seam, and the compiler finds every conformer.
- **K2, `package`:** `syncTurnNow`, `settleTurn`, `syncTurnTicket` (now queries), and the new `LiveLandTurns`, `ReplayLandOwner`, `KeeperOwner`.
- **K6:** `CanJoin` takes `ValidateContext` and returns a plan that `OnJoin` receives (#588, agreed with the maintainer 2026-11-18). It is a break, and K6's PR lists every changed signature. The maintainer confirms there that it needs no deprecation step.
- **Unchanged:** every public entry of `LandKeeper` keeps its signature and its contract (§3.3).
- **Behavior changes users can see,** each stated in its PR:
  - the follow-up arm order (K3);
  - the record order of a failure posted before queued inputs (K4);
  - the one refusal form for joins (K6);
  - AfterFinalize's emit, if K7 changes what it does today.

## 9. Questions

| Q | For | Question | Recommended |
|---|---|---|---|
| Q1 | maintainer | Where a re-evaluation keeper's model and world live until #612 (§3.10) | (c): the facade over two owners; replay has no core |
| Q2 | maintainer | The narrowed world (#758), or `@PlainData` on every land `State` (§3.1) | the narrowed world; `State: PlainData` probed in its own issue |
| Q4 | maintainer | #698 (the teardown notifies a transport other than the one it closed): fixed in K7, where the drain step uses the captured binding, or separately | in K7: #698 closes with it |
| Q6 | Code-1 | The world's shape (#758), the layout and executor in §3.10, G5's fit, and whether G9 and G10 belong in the core | — |
| Q7 | maintainer | The shared RNG finding (§3.1): confirm with a test, then an issue that moves the RNG state into the model | confirm first; not part of #700 |
| Q8 | maintainer | The `LandKeeperTransport` break (§8): as is, or a trapping default | as is |

Decided by Review in its check of rev 1: Q3 (the timers leave #700) and Q5 (the latch test is retired; coverage named in §6.1).

## 10. Prior art

- **Elm's `Cmd`/`Msg` and Erlang's `gen_server`** (CLAUDE.md's rule). A step returns work as data, and the result comes back as a message that re-reads current state. §3.4 applies that rule to each await.
- **Monitors and re-entry.** §3.7's trap on a synchronous step entry from inside a step is the monitor's re-entry check. `send` from a step is a message to self, which is queued, as in an actor's mailbox.
- **Capabilities over ambient references** (the object-capability discipline). §3.1's in-step port capability arrives with the input and is valid for that step and binding only. Rev 1's world kept a reference any step could copy out.
- **The strangler fig.** K1 extracts the bodies so the live and replay paths share them. K2 routes the live path through the core. #612 later removes the replay owner (Q1 (c)).

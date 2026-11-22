# LandKeeper's turns on the turn core (#700)

**Status:** rev 1 (§7's gaps G1, G2, G3 and G5 filed as #758–#761 on 2026-11-22), plan only, for Review's plan check and Code-1's turn-core fit read. No code until Review's GO, and none in a slice whose core gap (§7) is still open.

Code pointers are at main 8e622a20. `LK` is `Sources/SwiftStateTree/Runtime/LandKeeper.swift`, `TA` is `Sources/SwiftStateTreeTransport/TransportAdapter.swift`.

## 1. Goal and scope

#700 moves `LandKeeper`'s turns onto `TurnCore`. Keeper inputs become machine inputs, and work outside turns becomes keyed requests whose results come back as inputs. Each CLAUDE.md reentrancy exception that names the keeper ends on that model, or is stated as staying with its own issue.

**In scope.**
- Live keepers (`mode == .live`): every entry, every turn kind, the sync follow-ups, the failure mailbox, the action, join, leave, initialize and destroy resolvers, the debug freeze, the land-stop drain, the tick and sync loops.
- The #695 rebind and teardown tests as acceptance tests (§6.1).
- The CLAUDE.md reentrancy section, updated in the slice that ends each exception.

**Out of scope.**
- **Replay** (#612, parked by the maintainer; #550 folded into it). Re-evaluation keepers keep today's non-turn path, sharing the turn bodies (§3.10). #745 and #756 bind #612, not #700 (§3.10).
- The reevaluation monitor land's tick reading the runner service (#387 PR 2). It is a user handler, not keeper code.
- #744 (a land that refuses its initialization is recreated), #752 (replay takes one extra sequence number), the adapter's B-slices (#546 B1–B6).

**Prerequisites.**

| Prerequisite | State on 2026-11-22 |
|---|---|
| #546 L2 slices (L2a–L2d-3) | merged; L2d-3 is #746 |
| Coalesced follow-ups, quiescence wait (#702) | merged as #719 |
| One continuation job (#723) | merged as #734 |
| Post lane, now the mailbox (#725) | merged as #738 (names: `Mail`, `post`, `takeMail`, `handleMail`, `TurnMailbox`) |
| Lifecycle handler shapes (#593) | merged as #751; join and resolver items still open, and #700 takes them (§3.4, §5 K5–K6) |
| Shared deadline timer (#621 item 2) | PR #753, merge round; needed by K8 only |
| The core gaps in §7 | filed 2026-11-22: #758 (G1, blocks K2), #759 (G2), #760 (G3), #761 (G5) |

## 2. The keeper today, in short

- **No turn core.** LK doesn't import `SwiftStateTurns`. The only mention is LK:768–774, which calls the three sync follow-up slots "TurnCore's request-per-key shape (#700)… kept by hand".
- **A turn is a synchronous actor function.** `runTickTurn` LK:4679, `runInputTurn` LK:5675, `runSyncOnlyTurn` LK:5056 and `settleTurn` LK:1629 have no `await` between apply and outputs. Every live keeper routes through them (`routesThroughTurn`, LK:735). The sync phase runs in the turn when the port shares the keeper's executor (`syncsInTurn`, LK:742). The adapter adopts the keeper's executor (TA:105) and calls back with `assumeIsolated`.
- **One input queue.** `pendingItems` LK:372 holds actions, client events, lifecycle items, server inputs, the shutdown and the land failure. All turns apply through `applyInputs` LK:3917.
- **Work outside turns** is a `Task` that calls an actor method, which re-checks by hand:
  - action jobs: `startActionJob` LK:2289, then `completeAction` LK:2336 with `validateDelivery` LK:2211;
  - join: LK:1866–2057, with `players` written at LK:1965 between awaits;
  - leave: LK:2619–2741, with `players` written before the OnLeave await;
  - initialize: the init's eager `Task` LK:1073, then `performInitialization` LK:1252;
  - destroy handlers: LK:5986;
  - the three sync follow-ups: LK:5089, LK:5117, LK:5270;
  - the freeze loop: LK:1531;
  - the drain: LK:5896.
- **Waiters** are continuations:
  - tickless turn waiters (`awaitInputTurn` LK:5603), resumed after the record submission (`resumeInputTurnWaiters` LK:5728);
  - `awaitActionResult` LK:2468;
  - the freeze waiters;
  - `shutdownTurnWaiters` LK:5555.
- **Hand-rolled core features:**
  - `GenerationTable` for the sync binding (LK:5147);
  - `EpochCounter` for entry generations (LK:360);
  - `SingleFlight` for `forceShutdown` (LK:2774);
  - the requested-sync-work counter and its waiters (LK:5304–5357);
  - `LandFailureMailbox` (#732).

## 3. Design

### 3.1 What the core holds, and what goes outside the machine (G1, Q2)

`TurnCore.init` requires `M: PlainData`. Most of the keeper's data isn't plain:
- the land's `State` (`State: StateNodeProtocol`, only `Sendable`);
- queued payloads, held as existentials in `PendingItem`;
- player sessions, which hold `services`;
- the `OutputCollector` class, which every `LandContext` captures (LK:3335);
- the recorder;
- the port, which is the `LandKeeperTransport` existential.

The adapter's answer is `CommitTools`, passed in through a `Query` and never stored (rewrite plan §2.1). It works because the adapter's non-plain data is touched in one routine, the commit. The keeper touches its non-plain data in every step: every input handler can write `State`. A query per step would be the coordinator-shaped API that #546's decision calls a review finding. An actor-side box with a borrow assertion would be a hand-rolled workaround for a core gap (core-gap-fix-core-first).

**Proposal (G1, #758): the core owns a second, unchecked value next to the machine, and lends it only to steps.**
- Sketch: `associatedtype World = Void`; `TurnCore.init(_:world:…)`; `Turn.world`, a `_modify` accessor reachable only through the step's `Turn`, plus `MailTurn.world`; and `flush` gets it read-only.
- The contract is a documentation rule the macro can't check: nothing reachable from the world is changed except through it. The keeper keeps that by construction: the world's references (collector, recorder, port box) are created by the keeper and handed to no one else.
- This keeps "changed only in steps" for the land's data, which the `CommitTools` route gives up.
- Code-1 judges the shape. The plan needs only:
  - mutable access from every step kind (`handle`, `handleMail`, `answer`, follow-ups);
  - no access outside steps on the live path.

**The split, which K1 makes without the core:**

| Part | Holds | Stored |
|---|---|---|
| `KeeperModel` (`@PlainData`) | counters (`nextTickId`, `lastCommittedTickId`, sequence watermark, pass ordinal), flags (`isDraining`, `shutdownRequested`, `didInitialize`, `inTurnSyncDue`, `pendingFold`), the pending queue's order index, membership ids and entry generations, action-job bookkeeping, freeze generation and held counts, follow-up binding marks | the machine |
| `LandWorld<State>` | `state`, queued payloads, player sessions, `OutputCollector`, the recorder handle, the bound port | G1's world |
| `LandConfig` | definition, handlers, services, logger, intervals, limits | an actor `let` (immutable configuration, not state) |
| Tasks and continuations | — | **none**: K2–K7 replace each with a request, a `run`, a follow-up, a hold or a reply (§3.4, §4) |

K1's PR lists every stored field of `LandKeeper` and its home. A field that fits no row is a finding for Review.

**Q2 (maintainer):** G1 above, or require `@PlainData` on every land `State` (a public break)? `@PlainData` gives the full compile-time check for `State`, but not for payloads, sessions or the collector, so G1 is needed either way. **Recommended: G1.** Whether `State` could later be `PlainData` needs a probe of `@StateNodeBuilder`'s storage, and can be its own issue.

### 3.2 Keys

| Key | Lifetime | What it scopes |
|---|---|---|
| `.land` | started at init, `endAll` at the end of the drain | the land's own requests: record submissions, the drain's destroy handlers |
| `.initialization` | started at init, ended when initialization finishes or fails | the OnInitialize resolver request; inputs held behind it (§3.3) |
| `.entry(PlayerID)` | started on join, superseded by a rejoin, ended on leave | that entry's resolvers (CanJoin, OnJoin, OnLeave) and its action jobs. Its generation replaces `entryGenerations` (LK:1963) |
| `.actionJob(UInt64)` | started when an action with resolvers is admitted | the job's resolver request. Ending the entry ends its jobs, which replaces `cancelActionJobs(ofEntryGeneration:)` LK:2500 |
| `.syncBinding` | `start` on every bind or rebind, `end` on `setTransport(nil)`, `endAll` at teardown (#702 plan §5.1) | slots `.drainRetry`, `.joinSync`, `.afterTurn` |
| `.freeze` | started by `debugFreeze`, ended by resume, shutdown or timeout | the settle's gate and the freeze timeout timer |
| `.tickLoop`, `.syncLoop` | K8: the loops' timers (§3.9) | — |

A key per binding and per entry follows `Turn.start`'s rule: inputs that arrive while a key isn't live step under the next generation, so a fresh generation per bind is required (Turn.swift:47–51).

### 3.3 The keeper's inputs as machine inputs

| Today's entry | Machine input | Policy | Reply | Notes |
|---|---|---|---|---|
| `handleActionEnvelope` LK:2864, `submitAction` LK:2892 | `.action(envelope, ticket)` | `.normal`, waits for `.initialization`; behind the freeze (§3.3.1) | the action result, sent by the turn that applies it: `turn.reply(to: id, …, after: recordRequest)` | Tick lands keep the caller's `InputID` with the pending item, and the tick turn replies. Per-message cost: §3.8 |
| `handleClientEvent` LK:3083 (`async throws`) | `.clientEvent(...)` | as above | admission only (intake, as today) | §3.8 |
| `submitServerInput` LK:3198 | `.serverInput(...)` | as above; the frozen path holds it as `serverInputsHeldWhileFrozen` does | `ServerInputOutcome` | the sequence is taken at intake, as #387 decided |
| `join(session:…)` LK:1833 / `joinReportingAdmission` LK:1866 | `.join(...)` | `.normal`, waits for `.initialization` | the admission | K2: today's segments as steps; K6: #588's validate and apply in one step |
| `leave(…)` LK:2619 | `.leave(...)` | `.normal` | `Void` / error | membership changes in the step, then OnLeave as a request |
| init's eager `Task` LK:1073 | `.initialize` (sent by the init) | `.control` | — | `ensureInitialized` callers become inputs held on `.initialization`; the init still returns at once (#744 unchanged) |
| tick loop LK:3402, `stepTickOnce` LK:3456 | `.tickDue(instant)` | `.control` | `stepTickOnce`: after the tick's record request | K2–K7: sent by today's loop Task; K8: a core timer |
| sync loop LK:5739 | `.syncDue(instant)` | `.control` | — | same |
| `syncTurnNow` LK:5249 (sync, from the adapter) | `query(.syncTurnNow(port, reason, ticket))` | a query is a step, synchronous | `SyncTurnOutcome` | §3.7: never from inside a keeper step |
| `syncTurnTicket` LK:5235 | `query(.syncTurnTicket(port))` | — | the ticket (now `.syncBinding`'s generation) | — |
| `settleTurn` LK:1629 | `query(.settle(port, fence))` | — | `SettleTurnOutcome` | — |
| `setTransport` LK:484 | `.bind(port?)` | `.control` | — | `start`/`end(.syncBinding)` |
| `debugFreeze` LK:1531 / `debugResume` LK:1562 | `.freeze(gen, timeout)` / `.resume` | `.control` | freeze: when the settle completes or times out | K7 |
| `forceShutdown` LK:2761 | `.shutdown` | `.control` | after the shutdown turn's record and the drain | replaces `SingleFlight`: a second `.shutdown` joins the first's reply list |
| `notePendingFailure` LK:575 (nonisolated) | mail `.landFailure(f)`, capacity 1 | mail | — | K4 (§3.6) |
| `submitLandFailure` LK:5438 | removed in K4 | — | — | post-lane plan §4.2 |

**Results that come back** (§3.4):
- `.actionResolved(seq, Result)`;
- `.joinResolved(...)`, `.leaveResolved(...)`;
- `.initializeResolved(Result)`;
- `.destroyHandlerResolved(...)`;
- `.recordSubmitted(turn)`;
- `.writerDrained`, the `.drainRetry` follow-up's gate return;
- `.drainFinished`.

#### 3.3.1 Holds behind initialization and the freeze

- **Initialization.** Today intake awaits `ensureInitialized` and, on tickless lands, `debugWaitWhileFrozen` LK:1683. On the core, both are holds:
  - an input that needs the land initialized is `.normal(waitsFor: .initialization)`;
  - the initialize step holds that key until the resolver request closes, using `Hold.untilRequestCloses`.
- **The freeze.** Tickless intake while frozen is parked behind the freeze key's hold. A tick land keeps today's rule: inputs queue and the frozen tick doesn't run.
- **Order.** Queued inputs are FIFO per hold key, which is today's arrival order.

#### 3.3.2 Membership facts kept (from #612's rev-3 and rev-4 reviews)

The line numbers in this list are from those reviews, at an older commit; K1 re-points them at its base. Each fact is a test that K2 must keep green:
- `players` changes before the resolvers' await (then LK:1576/1798/2494); on the core, in a step.
- In-boundary clears belong to their own boundary: the shutdown (then LK:3619) and `failLand` (then LK:5285).
- A reconnect with no handler still changes `players`.
- A join that didn't complete is rolled back (then LK:1628/1856/5586).
- Today's tick-turn order is unchanged: W1, inputs, W2, the handler, the committed tick and hash, the port, the record enqueue; and the failed-input-prefix path.
- Waiters resume after the record submission (#612 rev-2 MF2b). On the core this is `reply(…, after: recordRequest)`.
- The live hash gate stays `mode == .live && reevaluationRecorder != nil && usesInTurnSync`.

### 3.4 Work outside turns as keyed requests

| Work | Today | On the core | Slice |
|---|---|---|---|
| Action resolvers | a `Task` per job, `completeAction` re-checks job, entry generation and caller cancellation | `turn.request(.resolveAction(snapshot), for: .actionJob(seq))` started in the intake step. The completion is `.actionResolved`. A closed job (entry ended, caller cancelled, land closing) runs `handleAbandoned` and replies `landClosed` or cancelled, as `validateDelivery` does today. Caller cancellation is `sendAndWait`'s `CallerCancellation` | K2 `run` + hand checks; K5 `request` |
| CanJoin / OnJoin / OnLeave resolvers | awaited inside `join`/`leave` | requests under `.entry(pid)`. A superseded entry closes them, replacing the generation checks at LK:2016, LK:5853 | K2 `run`; K6 `request` |
| The old session's kick on a duplicate login | `try await leave(...)` LK:1937 | in the join's step: membership change, then the old entry's OnLeave as a request (#588) | K6 |
| OnInitialize resolvers | awaited in `performInitialization` LK:1297, then a direct write LK:1339 | request under `.initialization`; `.initializeResolved` validates and applies (#593's two phases) in its step | K5 |
| Destroy handlers | awaited in the drain, no re-check by design | requests under `.land`, in today's order, one at a time (`queue` behind the previous) | K7 |
| Record submission | `await submitTurnRecord` LK:5019, then turn waiters resume | `request(.submitRecord(turn), for: .land)`; waiters are `reply(…, after:)` that request. Submission order stays the tracker's (LK:809) | K2 |
| Sync follow-ups (3 slots) | Tasks with binding marks | #702 plan §5 as written (§3.5) | K3 |
| In-turn sync | synchronous already (`runSyncPhaseInTurn`) | unchanged, called from the step with the world's port (§3.7) | K2 |

**Resolver snapshots.** A resolver gets `ResolverContext`, which holds a `currentState` snapshot and `services`, and no emit or sync request (ResolverContext.swift:37–95). So a resolver as an off-actor request reaches no keeper data. The effect carries the snapshot, taken in the step.

**Cost.** A core `request` costs about 13.1k instr over direct (#624). Actions with resolvers today already create a `Task` and hop twice, so K5's A/B compares like with like. Actions without resolvers make no request (§3.8). If K5's A/B shows a regression, #621 item 3 (effect hops) is the core fix, not a keeper shortcut.

### 3.5 Sync follow-ups: #702 plan §5, adopted as written

- **Key and slots.** `.syncBinding`, with slots `.drainRetry` (`.afterWork(.waitForWriterDrain(port))`), `.joinSync` and `.afterTurn` (both `.afterBatch`).
- **Bind and teardown.** Every bind is `start`, `setTransport(nil)` is `end`, and the teardown is `endAll`.
- **The port.** The gate effect carries its port, and the first requester stays weak.
- **Handler check order:** `mode == .live`, `failure == nil`, `!isDraining`, `port.runsSyncPhaseInTurn(of:)`. The join-sync turn re-checks `transportHasJoinsAwaitingSync`.
- **`syncTurnNow`'s order:** accept (port and generation), then consume, then the phase. A stale ticket returns `.skipped` and consumes nothing.
- **Counters** as §5.4 places them. `.keptEvents` moves to the machine.
- **Waits.** `waitForRequestedSyncTurnsForTesting` maps to `waitForQuiescence(.followUps, of: .syncBinding)`, and the requested-sync-work counter and waiters (LK:5304–5357) are deleted.
- **The intended ordering change.** Join-sync and after-turn follow-ups armed by one commit run in arm order, not as two Tasks. It goes in K3's PR body, and the harness row `join-during-writer-backlog` shows whether any golden moves.

### 3.6 The failure mail and staging: #725 plan §4, refined

`LandFailureMailbox` becomes the core's mailbox: `Mail = LandReport` with capacity 1. `notePendingFailure` becomes `post(.landFailure(f))`. Each `finishApply`/`applyPendingTransportFailure` read becomes a `turn.takeMail()` checkpoint, per the plan's §4.1:

| Turn kind | Checkpoints |
|---|---|
| any | the driver's pre-step check (automatic) |
| initialize | after `finishApply`, even with no `OnInitialize` |
| tick | after apply and handler; before `runTurnOutputs` |
| tickless input | after `takePassOrdinal`; before `if failure != nil`; before the outputs |
| sync-only | the start of the step |
| settle | the start of the step; returns `.failed(f)` |

**Staging (the refinement §4.1 asked for).** A turn's events and replies go to the world's `OutputCollector` and to a staged reply list during the step. They reach `turn.emit` and `turn.reply` only after the last checkpoint, which is after `finishApply()` (#716's rule: no `emit` before `finishApply`; the S1b mutant keeps failing). A failure found at a checkpoint drops what is staged, and the callers get `landClosed` (#716 Q5's words).

**Removed:** `submitLandFailure`, `.failureSubmit`, and the adapter's awaited submit in `failOutsideTurn` (TA:5656), which keeps `post` and the gate close.

**The record's shape change** (post-lane §4.2): a report taken before a step fails the land ahead of the inputs still queued. K4's PR body states it, and a test pins it: two inputs queued, a post, then the turn; the record holds the failure first, and both inputs are refused.

**Core recording stays off.** The keeper records through its own recorder. It doesn't set `onMailTaken`, so the core's mail record is never written (§3.10).

### 3.7 Calls into the keeper during its own step

The in-turn sync phase calls the adapter synchronously (`transport.runSyncPhaseInTurn`, LK:4597, LK:5071). The adapter calls back into the keeper through `assumeIsolated`: `recordsSyncStream` (TA:3801) and `submitSyncStream` (TA:3829, TA:3956).
- On the core, a call back into the actor during a step that steps the core is a `fatalError`, and these callbacks touch the recorder, which is in the world.
- **Rule:** the port's in-turn API takes the step's handle. `runSyncPhaseInTurn(…, keeper: KeeperStepAccess)` passes a non-escaping value through which the recorder calls go. No in-turn callback names the keeper actor.
- **The audit.** Every adapter call into the keeper is listed with whether it can run inside a keeper step: the ~20 sites in the code map (`syncTurnNow` at TA:3128/3181/3201/3494/5099/6374, `settleTurn` TA:6223, `entrySession` TA:1458, …). One that can is converted to the step handle. One that can't stays a `query` or `send`.
- **Debug check.** A debug assertion in each keeper entry refuses a call from inside its own step. It is the core's own check (stepping inside a step), reported with the entry's name.

### 3.8 The per-message path: intake cost

Actions and client events are per-message. #546's decision budgets about +100 instructions per message for the core's reads. `sendAndWait` costs a waiter (`call` about 2.9k instr over direct, #624), and today's tick-land client event returns after intake with no waiter.

| Path | Mechanism | Cost over today (expected) |
|---|---|---|
| Client event, land initialized and not frozen | `query(.admitClientEvent)`: one synchronous step, the answer is the admission | one step (read1 is 13 instr over direct, #624), within budget |
| Client event, before initialization or while frozen | `sendAndWait`, parked behind the hold | a waiter, off the steady state |
| Action, tick land | intake as a query, as above, then the caller awaits the result. Today's `awaitActionResult` continuation becomes a reply waiter: one waiter for one continuation | about equal; K2's A/B measures it |
| Action, tickless | `sendAndWait`; the reply after the record request | one waiter, replacing `awaitInputTurn`'s continuation |

**G5, a candidate core issue (#761).** A `send` that steps at once could return the step's admission (refused, accepted). It would make the query path unnecessary. Code-1 judges whether that fits the core. Until then, the query fast path above is the plan.

### 3.9 Ticks and the sync loop (Q3)

- **Today.** The tick loop is a `Task` with a fixed rate, skip-ahead and a phase offset (LK:3402–3441, `TickLoopClock` for tests). The sync loop is another `Task` (LK:5739), and the fold rule reads the next tick deadline (LK:787).
- **K2–K7.** The loop Tasks stay as drivers. Each wake sends `.tickDue(now)` or `.syncDue(now)`, and the fold rule moves into the `.syncDue` step. This keeps K2's cut-over off the clock.
- **K8.** Both loops move to core timers: `turn.timer(at:for: .tickLoop)`, whose fire carries its instant, so skip-ahead is the handler's arithmetic. The first arm is at the phase offset. This needs:
  - #753's single sleeper, without which every tick is a `Task`;
  - a production `TurnClock` over `safeTaskSleep` (G2);
  - `TickLoopClock`'s test hook moved to a test `TurnClock`.
- **Q3 (Review):** K8 inside #700, or a follow-up issue after it? **Recommended: inside**, as the last slice before the deletions, so #700 ends with no keeper-owned Task except the drivers it names.

### 3.10 Re-evaluation keepers until #612 (Q1), and where #745 and #756 fit

Re-evaluation keepers run the replay path (LK:4254–4553, `replayRecordedPasses` LK:3998, `replayInitializeBeforeTickZero` LK:1195). It awaits the source between turn segments. That is CLAUDE.md's listed exception "until #612". #700 leaves it in place, and replay E2E (0 mismatch) runs on every slice.

**Q1 (maintainer): where a re-evaluation keeper's model and world live until #612.**

| Option | What it means | Cost |
|---|---|---|
| (a) | The core lends machine and world mutably outside steps to a core that is never stepped (a package API, trapping if the core ever stepped) | a core API that exists only for an exception |
| (b) | Replay ticks and passes become core inputs; the source awaits move into the replay driver | a replay redesign, which is #612's work |
| **(c), recommended** | A re-evaluation keeper holds `KeeperModel` and `LandWorld` in actor storage. Its path calls the same synchronous turn bodies as K1 makes them. A live keeper holds them in the core. One storage enum, switched once per entry | two owners of one value, adopter-internal; #612 deletes the replay owner |

With (c), a re-evaluation keeper never steps a core. That gives the boundary #612's 2026-11-22 comment asks for, structurally, without a per-entry refusal: the replay owner has no live entries. A debug assertion and a test pin it.

**#745 and #756.** Both concern the core's own record and replay: where a continuation job lands against the next input, and timer wake boundaries in mail replay. #700 uses neither:
- live keepers record through the keeper's recorder, and the core's mail record is never enabled (`onMailTaken` unset);
- re-evaluation keepers never step a core (Q1 (c)). They also have no port, so no `.syncBinding` follow-up, and no tick timer.

So #756's "before any adopter records mail" holds, and #745's limitation never meets a keeper path. Both stay with #612, which decides their shapes (#756: "decide the shape together with #612").

A test pins the invariant: a re-evaluation run's core stats show zero steps, zero mail and zero continuation jobs.

## 4. How each CLAUDE.md exception ends

| Exception (CLAUDE.md) | Code today | Ends in | How |
|---|---|---|---|
| Join/leave resolvers | LK:1866–2057, LK:2619–2741 | K2 (steps), K6 (#588) | Membership changes in a step; resolvers are requests under `.entry(pid)`; a superseded entry closes them; CanJoin validates and OnJoin applies in one step; the old session's leave is in that step. #548's in-turn variant is a test |
| Freeze drain/settle (#129): `debugFreeze` re-checks its generation and registers its waiter after each await | LK:1531–1556 | K7 | `.freeze(gen, timeout)` starts `.freeze`, arms its timeout timer and asks for the settle. The caller's reply comes from the settle step or the timer, so no await loop and no hand re-check: a newer freeze supersedes the key |
| Action frame bookkeeping after the resolvers: `debugEndWork` and the tickless turn waiter (`awaitInputTurn`) | LK:1696, LK:5603 | K2 (waiter), K5 (`debugEndWork`) | The waiter is a reply. In-flight work is the machine's count, changed in the intake step and in the result or abandonment step |
| Land-stop drain's post-await bookkeeping (#522) | LK:5896–5964, LK:5970 | K7 | `.drain` captures the land's state in its step (the epoch is `.land`'s generation; #522's "drain finished (ticket)"). The destroy handlers are requests queued in order, and `.drainFinished` does the release in its step. #698: Q4 |
| `LandFailureMailbox` stands in for the core's mailbox (#732) | LandFailureMailbox.swift, LK:565–575 | K4 | §3.6 |
| Re-evaluation keepers' non-turn replay path (#612) | LK:4254–4553 | **stays** until #612 | §3.10 |
| Reevaluation monitor tick (#387) | ReevaluationMonitorLand.swift:28–70 | **stays** until #387 PR 2 | not keeper code |

Not listed in CLAUDE.md, but the same class, and they end too:
- OnInitialize resolvers followed by a direct write, and `didInitialize` set after an await (LK:1103–1105): K5.
- The tick land's force shutdown: `waitForTickInFlight`, then a shutdown turn that writes `nextTickId` before an awaited record (LK:2796–2799): K2.
- `runTick` writing `nextTickDeadline`, `ticksInFlight` and `nextTickId` before entering `runTickTurn`: K2, all inside the `.tickDue` step.
- `tearDownAfterFailedInitialization` (LK:1173): K5.

## 5. Slices

Every slice is its own PR to `main`, after Review's plan check on this plan.

**Verification every slice runs:**
- `swift test` on both legs;
- `Examples/Demo` and `Examples/GameDemo` `swift test`;
- E2E in all three encodings, and the game E2E with reevaluation (0 mismatch);
- `swift build -c release`, plus the release filter on the touched suites;
- must-not-compile;
- one mutant per new rule.

**The differential-harness pass every slice runs** (adapter differential harness, rev 10; 84 cells, all in-turn since L2c):
- goldens are compared bytes first in the pinned 6.2.4 image;
- `scripts/differential-gate.sh` passes with `ran + replaced == listed`, `ran > 0`, `compared == run`, `threw == 0`;
- each difference is in `ExpectedDifferences.swift` (exact, one cell, one use) with its cause, classified by `scripts/classify-golden-changes.py`.

The "expected" column says which differences are allowed.

**Host A/B tiers** follow the proportional rule:
- full A/B = #554's five cells plus `nonsync`, ABBA with 5 pairs, a regression is more than max(0.5 %, 3× spread) on `instructions:u` (rewrite plan §5);
- small = 1–2 cells.

| Slice | Content | Needs | Harness: expected differences | Host A/B tier |
|---|---|---|---|---|
| **K1** | Storage split (§3.1) and turn bodies as synchronous functions over `(inout KeeperModel, inout LandWorld, LandConfig)`. Every multi-await flow's segments become named synchronous functions. No core; behavior unchanged. Re-evaluation keepers call the same bodies | — | none | **small**: the default production cell and `rows-mp`. The hot path's field access moves into structs, and codegen can move |
| **K2** | The cut-over. `LandKeeper: TurnActor` for live keepers; model and world in the core (G1); every live entry is a core entry (§3.3); each K1 segment is a step; each await between segments is a `turn.run` whose result is an input, with today's hand checks kept in the handlers; record submission as a request and waiters as replies (§3.4); the in-turn port API takes the step handle (§3.7); intake per §3.8. The loop Tasks are drivers (§3.9); follow-ups and the failure box as today | G1, G3 | none | **full**: a turn-core adoption step on the keeper's hot path |
| **K3** | Sync follow-ups on the core (§3.5): the three slots, `waitForQuiescence`; delete the hand-rolled slots and the requested-sync-work waiters; the #695 acceptance tests rewritten (§6.1) | K2 | only the arm-order change (§3.5), if a cell shows it | **Mac output check**: follow-ups arm on writer backlog and joins, off the steady-state path; one EncodingBenchmark cell, frame counts and bytes identical |
| **K4** | The failure mail (§3.6): mailbox capacity 1, checkpoints, staging, the record-shape change; delete `LandFailureMailbox`, `submitLandFailure`, `.failureSubmit` | K2 | failure rows' record order, if a cell covers a post before queued inputs | **small**: the mailbox costs every entry (+396 emit, +440 call, post-lane §3.8); the default cell and `rows-mp`, and this slice sets the budget that §3.8 left open |
| **K5** | Resolvers as keyed requests: action jobs under `.actionJob` (abandonment replaces `validateDelivery`'s checks), OnInitialize under `.initialization` (initialize as a turn; `ensureInitialized` waiters as held inputs), `debugEndWork` as the machine's count | K2 | none | **small**: the default cell and a cell with an action resolver. If no benchmark cell has one, add it in a tool-only commit first (Mac output check for that commit) |
| **K6** | Join and leave per #588: CanJoin is `validate` with `ValidateContext` returning a plan, OnJoin is `apply`, in one step; stale-join refusal, `maxPlayers` (reconnection exempt), the duplicate-login kick and the draining guard in that step; one refusal form; a recorded refused join; #548's tests | K5 | join-refusal rows, if #588's one refusal form changes their bytes | **small**: one cell where joins dominate. Review names it; ServerLoadTest's ramp is the candidate, and if no cell isolates joins, K6 records a `call` and takes a Mac output check |
| **K7** | The freeze (#129) and the land-stop drain (#522) on the core (§4); forceShutdown's `SingleFlight` replaced (§3.3) | K5 | none: the `freeze-resume-*` rows must stay byte-identical | **none**: debug freeze and teardown are off the measured paths. Recorded as a `call` with that reason |
| **K8** | Tick and sync loops as core timers (§3.9) | #753, G2 | none | **small**: the default cell and the cell with the highest tick rate |
| **K9** | Deletions: `GenerationTable`/`EpochCounter`/`SingleFlight` uses in the keeper, replaced `HoldPoints` (§6.3), dead `.live` arms (`flushOutputs` LK:674–691, `runSyncRequests` LK:718, the recorder branches at LK:3871, 4523, 4540, 1404–1413, each first proven unreachable). CLAUDE.md's reentrancy section rewritten: the keeper exceptions left are #612 and #387 | K1–K8 | none | **Mac output check** |

**Ordering notes.**
- K1 can start before G1 lands: it shapes the split so K2 drops it into the core unchanged.
- K3 and K4 are independent of each other, and K5 is independent of both.
- K6 needs K5's request handling.
- K7 needs K5 for the destroy handlers as requests.

**Stop conditions** (#546's decision, applied to the keeper):
- If a slice needs a coordinator-shaped machine API (a query that runs arbitrary keeper code, or a switch at each write), stop and redo this outline.
- If K9's deleted scaffolding is smaller than the machine code K2–K8 added, Review revisits.
- A core gap found mid-slice stops the slice: it is reported, fixed in the core, and the slice resumes (core-gap-fix-core-first).

## 6. Tests

### 6.1 #695's acceptance tests

#700's issue names three:

| Test | On main | At #700 |
|---|---|---|
| Rebind with a held retry: `olderBindingsRetryDoesNotBlockTheCurrentOne` (`TransportAdapterRequestedSyncTurnTests.swift`) | yes | K3 rewrites it per #702 plan §5.5 (b)–(d). B's follow-up is `.armed` while A's gate waits. A's late gate return steps nothing (a step counter). B still delivers stamp 2 while A's writer is held. Its mutant (a keeper-wide slot) must still fail it |
| Teardown with an armed retry: `teardownEndsAnArmedRetry` | yes | K3. Slot quiescence after the teardown, **plus** a separate observation that A's gate returned after the teardown: quiescence alone would pass with a stranded gate. Its mutant (the writer teardown not releasing its drain waiters) must still fail it |
| Latch window: `syncDuringSettleCycleIsLatched` | **no** | Retired in L2b (#712, ef23c7a7: "an in-turn settle no longer latches"); the latch slot was deleted in L2d. Nothing to port. Q5 asks whether Review wants a replacement |

**K3 adds:**
- #702 plan §5.3's keeper test: a stale lag request with an after-turn follow-up pending leaves it pending, and it steps.
- #695 round 3's known gap: an older binding's retry, still waiting on its writer, outlives a teardown that reaches only the new binding's writer. It must be closed by `endAll`, and the test asserts it doesn't stay counted. This is the case the core removes.

### 6.2 New tests per slice

All tests force interleavings with holds (`HoldPoints`, `TestGate`, a gated `perform`), never timing, and bound every wait (`withinDeadline`, `withinHangBound`).

| Slice | Tests |
|---|---|
| K1 | the field census test: every stored property of `LandKeeper` is in the model, the world, the config or the K2–K7 replacement list (a `Mirror`-based check, so a new field fails it until placed) |
| K2 | per entry: a call from inside the keeper's own step traps in debug (§3.7). Waiters resume after the record (MF2b), with the record request held. Intake parks behind `.initialization`. The tick land's shutdown applies inside its `.shutdown` step with no tick in between. A re-evaluation keeper never steps its core (§3.10) |
| K3 | §6.1 |
| K4 | two inputs queued, a post, then the turn (§3.6). Staged outputs are dropped on a checkpoint failure. No `emit` before `finishApply` (the existing S1b mutant) |
| K5 | an action job's caller cancels while its resolver is held: the job is abandoned and the caller gets `CancellationError`. The entry leaves while its job's resolver is held: abandonment, `landClosed`, nothing applied. Initialize's resolver is held while a join arrives: the join parks, then is admitted |
| K6 | #588's checks in one step, each refusing in one form. #548: hold the join's resolver, tear down, release with `.allow`: no membership, slot, joining record or connection generation is left, plus the in-turn variant. A duplicate login's old OnLeave runs as a request |
| K7 | #129's freeze/resume interleaved with a deferred writer retry, held at the former await. A newer freeze supersedes an older one's settle. The drain: a `leave` that arrives during the destroy handlers is refused. `forceShutdown` twice gives one drain and two replies |
| K8 | the tick timer's skip-ahead, with a test `TurnClock` moved past three periods. The phase offset is the first arm. The fold window reads the timer's next instant |

### 6.3 The keeper's hold points

LK:55–82 has 11 points.
- **K2** keeps each point's position where it still exists, now inside a step or a `perform`.
- **K5 and K7** move the points that sat between an await and a write to the effect, inside `perform`: `.actionComplete`, `.join`, `.leave`, `.drainStart`, `.landFailedTeardown`. The interleaving they forced is now a held completion with other inputs stepping meanwhile.
- **K4** deletes `.failureSubmit`. **K9** deletes points with no remaining user.

Each slice's PR lists the tests whose hold moved.

## 7. Turn-core gaps (to report as core issues, per core-gap-fix-core-first)

| # | Gap | Tracked | Blocks | Proposed |
|---|---|---|---|---|
| G1 | Step-lent non-plain world: the keeper's land state, payloads, sessions, collector, recorder and port can't be machine state (§3.1) | **#758** (foundation) | K2 | Code-1 to judge the shape |
| G2 | A production `TurnClock` over `safeTaskSleep` | **#759** (foundation); planned in #546 B1, which had no issue | K8 | whichever of K8 and B1 comes first adds it |
| G3 | Specialization of a **generic** machine (`TurnCore<KeeperMachine<State>>`): `check-turns-inlinable.sh` and #624 checked concrete bench machines only | **#760** (foundation) | K2's A/B reading | extend the check to a generic machine instantiated from another module; a core change only if it fails |
| G4 | One sleeper for all deadlines | #753 (#621 item 2) | K8 | — |
| G5 | `send` returns `Void`; a synchronous admission answer would replace the query fast path (§3.8) | **#761** (before-release) | nothing (the query path works) | a candidate; Code-1 to judge |
| G6 | Effect launch and hop cost (`request` about 13.1k instr) | #621 item 3 | only if K5's A/B regresses | — |
| G7 | Waiter table cost (`call` about 2.9k instr) | #621 item 4 | only if K2's A/B regresses on actions | — |
| G8 | The mailbox's per-entry cost has no budget | post-lane §3.8 open item | K4 sets it | — |

Not gaps for #700: the core's input recording, `.cancelsCall` in replay, #745 and #756, all replay (§3.10).

## 8. Public API

- **K1–K5, K7–K9:** no public change. `LandKeeper`'s public entries keep their signatures. `syncTurnNow`, `settleTurn` and the port's in-turn methods are `package`, and K2 changes them (§3.7). `LandKeeperTransport`'s in-turn method gains the step handle: a `package` change, listed in K2's PR.
- **K6:** `CanJoin` takes `ValidateContext` and returns a plan that `OnJoin` receives (#588, agreed with the maintainer 2026-11-18). This is a break, listed in K6's PR with every changed signature, and the maintainer confirms the deprecation question there: none, as #593 did, unless they ask for it.
- **The behavior changes users can see**, each stated in its PR:
  - the follow-up arm order (K3);
  - the record order of a failure posted before queued inputs (K4);
  - the one refusal form for joins (K6).

## 9. Questions

| Q | For | Question | Recommended |
|---|---|---|---|
| Q1 | maintainer | Where a re-evaluation keeper's model and world live until #612 (§3.10) | (c): actor storage, same turn bodies, never a core |
| Q2 | maintainer | G1's step-lent world, or `@PlainData` on every land `State` (§3.1) | G1; a probe of `State: PlainData` as its own issue |
| Q3 | Review | K8 (the loops as core timers) inside #700 or after it (§3.9) | inside |
| Q4 | maintainer | #698 (teardown notifies a transport other than the one it closed): fix in K7, where the drain step captures the port, or keep it separate | in K7: the captured port is the fix, and #698 closes with K7 |
| Q5 | Review | The latch-window test no longer has a window to guard (§6.1): accept "nothing to port", or name a replacement | nothing to port |
| Q6 | Code-1 | G1's and G5's shapes, and whether G3 needs a core change or only a check | — |

## 10. Prior art

- **Elm's `Cmd`/`Msg` and Erlang's `gen_server`** (CLAUDE.md's rule). A step returns work as data, and the result comes back as a message that re-reads current state. §3.4's table is that rule applied to each await.
- **Hoare's monitors and the "no await in a critical section" rule.** §3.7's trap on a call into the actor from its own step is the monitor's re-entry check.
- **The strangler-fig migration.** K1 extracts the bodies so the live and replay paths share them, and K2 routes the live path through the core. #612 later removes the replay owner (Q1 (c)).

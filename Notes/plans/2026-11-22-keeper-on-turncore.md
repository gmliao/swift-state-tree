# LandKeeper's turns on the turn core (#700)

**Status:** rev 5.2, plan only. Rev 4 had Review's GO. Rev 5 changed K1 and was NOT GO from Review (1 must-fix, 2 should, 1 nit); rev 5.1 answered them and has Review's GO (2fdcabf9), with two shoulds for K1a's implementation that rev 5.2 folds in (below). Q2 is decided: no world (§9). K2 is gated on the maintainer's Q1 and on G2 (#759). No code until the maintainer okays implementation, and none goes in a slice whose core gap (§7) is still open. Two implementation notes from rev 4's GO are in §3.2 and §3.10.

Code pointers are at main 8e622a20:
- `LK` is `Sources/SwiftStateTree/Runtime/LandKeeper.swift`;
- `TA` is `Sources/SwiftStateTreeTransport/TransportAdapter.swift`;
- `LKT` is `Sources/SwiftStateTree/Runtime/LandKeeperTransport.swift`.

**Rev 5.2** (Review's GO on rev 5.1, two shoulds for K1a):
- **The harness off the pinned toolchain** (§3.11, Harness). There canonical JSON bytes may differ, so the record's decoded view renders a recorded payload as its tree, not as base64. The rule is named `recordPayloadAsTree`. The classify script then sees no payload leaf change. Tests are named.
- **A replay decode failure kept as text** (§3.11, Replay's decode failures). The item can't keep the error value, so `applyPendingItem` throws a wrapper whose description is the stored text, and `PayloadNesting.TooDeep` keeps its own form. The consumers were checked: none inspects an action's error type in replay, and the client-event path inspects only `TooDeep`. Both are pinned in `replayPayloadDecodeFailureIsReportedAsBefore`.

**Rev 5.1** (Review on rev 5's delta):
- **MF1, §3.11: JSON bytes weren't stable.** Rev 5 kept the bytes of the live round trip, `JSONEncoder().encode(payload)` (InboundPayloadDecoding.swift:15). That encoder doesn't sort keys, and `AnyCodable` encodes a `[String: Any]` in the dictionary's iteration order, which follows the per-process hash seed. So the same payload gave different bytes per run, as `Notes/solutions/2026-11-07-encoded-bytes-vary-with-per-process-hash-order.md` describes. Rev 5.1 records **canonical JSON bytes**, encoded once for the record with a fixed configuration. The live round trip is untouched, so the live decode can't change. A two-process test pins the bytes.
- **Should, §3.11:** a 3.7 payload that fails to decode at replay is reported where today's apply-time decode failure is, with a test that pins today's report first.
- **Should, §3.11:** the test for a JSON-sourced item under a `messagepack` header is named.
- **Nit:** the status line names G2 beside Q1, as §5 does.

**Rev 5** (Q2 decided; K1 carries the recorded raw bytes):
- **Q2 = no world** (maintainer, 2026-11-22, with `2026-11-22-plaindata-all-the-way.md`). The core holds the model only, and the model holds every value the keeper's turns change: `State` (PlainData P4), the queued items, entry facts, the staged events. The land definition, its handler closures and `LandConfig` are the machine's `Behavior` (#768, merged 8a3f3e15), fixed at `TurnCore.init`. #758 is on hold and no longer blocks K2 (§7). §3.1 and §3.10 are rewritten for it; the other homes in §3.1's reference table are unchanged.
- **K1 splits into K1a and K1b** (§5):
  - **K1a, the record keeps raw bytes** (PlainData plan Q4 and its slice P5, §3.11). Each queued action and client event holds its payload as bytes plus the decoded typed value. The record writes the bytes, and the encoding goes once in the record header. Record format 3.7. The wire frames don't change; every golden's record bytes do;
  - **K1b, the census and the split** (rev 4's K1, without the world): byte-identical.
- **K1a's order:** after PlainData P3 and P4. K1b's after K1a. §3.11 lists what P3 must leave for K1a.
- **New questions:** K1-Q1 to K1-Q3 (§9), for the maintainer through Main.

**Rev 4** (Review's check of rev 3):
- **MF-a, §3.2: the result slot's lifecycle**, written down from today's `actionSlots` (LK:2251–2257, LK:2312, LK:2446–2460, LK:2466–2495). One slot per sequence, created at admission before `.pending` returns. It holds one terminal outcome or one waiter, and is consumed once. An outcome that arrives before the wait is kept. A second wait gets `ActionResultUnavailable`, and so does a wait after `endAll`.
- **MF-b, §3.2: entry end cancels the worker.** Ending `.entry(pid, eid)` abandons the request, but its effect's task keeps running. So the step that ends an entry, and the drain before `endAll`, cancel each affected job's `JobCancellation`, as `cancelActionJobs` does today (LK:2500–2529). The token is sealed once the slot has its outcome: a later `cancel()` changes nothing. Admission checks `Task.isCancelled` first: a cancelled caller gets `CancellationError` at intake (LK:3000–3001).
- **MF-c, §3.3, §3.3.1: server input is exempt from the freeze barrier.** While frozen it is admitted with its sequence and its in-flight cap charged, and held (LK:3246–3253). The resume step queues the held inputs before frozen client intake wakes (LK:1567–1574). An initialization failure answers it `.refused(.draining)` (LK:3203–3207).
- **MF-d, §3.10, §8: the public witness keeps receiving the facade.** `runsSyncPhaseInTurn(of keeper: AnyObject)` is public (LKT:94). An outside conformer may compare `===` against the keeper it holds, so the step passes the `LandKeeper` facade, as today. With that, rev 3's `KeeperIdentity` has no job left and is dropped. §8's "no public change in K2" holds.
- **Shoulds.**
  - §3.3.1: intake order is "the same as today", not a strict FIFO: callers woken from a barrier resume in executor order, and a fresh call can pass them, as today. The call-order test covers intakes that don't wait at a barrier. The K5 deadline is cited (ResolverDeadline.swift:17: default 30 s, 0 disables).
  - §3.1: the leave resolver's effect captures the outgoing per-player override before `flush` deletes it. The scoped emitter covers all three `LandContext` output closures (emit, request sync, request broadcast-only sync; LandContext.swift:150–156), and is safe from a task that outlives its step.
  - §3.4: `.recordTaken` is the completion of the ordered recorder call (`enqueueRecorderSubmission`'s task, LK:5019–5023).
  - §6.2: the drain's sweep also covers callers waiting on a record completion, and completes shutdown callers with success, not `landClosed`. The K2 test is fixed.
  - §3.10: the replay pin is a runtime `Mirror` test, not a compile-time check.
- **For the maintainer** (Main files them as decision issues): Q1, Q2 and Q4 (§9), each with what it changes in K1 and K2.

**Rev 3** (Review's check of rev 2, Code-1's fit read, Main's decisions):
- **MF2, §3.3: actions with resolvers stay two-phase.** The intake returns `.pending(sequence:)` at once, on tick and tickless lands (LK:3023), so the adapter releases its inbound chain (TA:5382–5404). The result comes from a separate `awaitActionResult`. On the core:
  - the admission is a query answering the pending token;
  - the result wait is its own `sendAndWait`;
  - no `Turn.reply` is made to a query.

  The join and leave rows are split by land kind:
  - a tickless join waits for application when admission doesn't complete in-turn (LK:2037–2056);
  - a tickless leave waits for application (LK:2733–2737).
- **New MF, §3.3: server inputs from a turn's requested work.** `ServerInputSubmitter.submit` is async and "from any task" (ServerInput.swift:61–79). The work a turn requests submits later. So it is an outside entry, `query(.admitServerInput)` from the work's task, including the frozen accepted-and-held path. Rev 2's "appends through the world" is withdrawn.
- **MF4, §3.2: a synchronous per-job cancellation token** (route (a), Main's decision; rev 4 adds the slot lifecycle, entry-end cancellation and the seal). It keeps today's guarantee: once `cancel()` returns, a completion that hasn't run yet won't deliver (LK:2466–2495).
  - The token is allocated before submission and carried by the request's effect.
  - It is checked at admission and at delivery, and cancels the worker synchronously.
  - No hop, and no `InputID` captured by the cancel side.
  - G10 (#764) isn't needed for K2: it stays a nice-to-have (Code-1).
  - Also kept: `.senderSuperseded` on entry end. Actions whose sender has no entry get the `.land` scope. OnLeave's work runs off the key the leave closes.
- **MF3, §3.7, §8: no public change in K2.**
  - `runSyncPhaseInTurn` makes no call back into the keeper. Its drafts already come back in `InTurnSyncOutput.syncStream`, and its recording flag comes in through `recording:` (LKT:180, TA:2839–2853, TA:3825–3832). So its signature stays, and rev 2's listed break is withdrawn.
  - The one in-step callback is the join-admission clear (`supersedeSessions` → `recordSyncStreamClear` → `submitSyncStream`, TA:1550, TA:1908, TA:3951–3956), reached through the public `admitJoiningSession` (LKT:116). It gets a package path, which takes the recording flag from the step and returns its drafts. The public requirement stays.
- **Code-1 (2), §3.1, §3.5: the port is a Sendable binding token**, the port reference plus its `BindingID`. It travels in inputs, queries and effects. The step checks the `BindingID` against the model, then calls the port synchronously. Since no port call reaches back into the keeper (above), no `~Copyable` capability is needed. Code-1 noted for #546 B: once the adapter has its own core on the shared executor, a keeper step that calls the adapter nests two cores, and that needs a rule then.
- **Code-1 (3), §3.1: the scoped emitter is a runtime scope.** It holds its step's token, and an emit after its step is dropped and counted, asserted in debug, like `emit` to a dead key (Turn.swift:265). `LandContext` stays a public `Sendable` struct: no public break.
- **MF5 hole and Code-1 (1), §3.3.1: no intake holds in #700** (rev 4 exempts server input from the freeze barrier and softens the order claim). A query steps directly and bypasses holds, the queue and `close`. So every intake kind, query or `sendAndWait`, passes the same entry barrier before it submits:
  - initialization, with its failure path;
  - the freeze, re-checked after the wake (LK:1088–1107, LK:1681–1689).

  No intake is ever parked by a hold, so a query can't overtake a queued action. Intake order stays as today, with a test. K5 makes initialization a request with a deadline but doesn't hold intake on it. Code-1 (4): the deadline is `RESOLVER_INIT_TIMEOUT_MS`, and its abandonment fails the initialization and answers the barrier's waiters.
- **Code-1 (5), §6.2: every waiter is answered before `endAll`.** `endAll` and `close` don't answer calls that already stepped, and the core asserts no waiters at deinit (TurnCore.swift:358). So the drain step answers every `InputID` the model keeps: tickless actions not yet applied, result waits, joins waiting for admission, callers waiting on a record completion, freeze callers (each `landClosed`), and the shutdown reply list (success; rev 4).
- **Code-1 (6), §3.10:** `notePendingFailure` on a replay keeper is a no-op, as today (LK:576).
- **Shoulds.**
  - §3.1: `SyncValueSemantics.validate`'s limits are stated, and the world's value rule is a documented rule, not a proof.
  - §3.1: per-player service overrides get a home outside the world.
  - §3.1: `AfterFinalize` gets its own context.
  - §3.10: the port holds and compares a keeper identity object (rev 4: dropped; the public witness keeps the facade).
  - §3.10: "replay has no core" is pinned from inside the package.
  - §3.10: the mailbox is typed `TurnMailbox<LandReport>?` from `core.mailbox`.
  - §3.10: `lint-turns.sh` approves the facade's forwarding boundary.
- **G9 and G10** stay filed (#763, #764), at priority before-release (Main): Code-1 found the freeze expressible today, and G10 optional. G9's cleaner shape is a holding request without an effect. #700 uses neither (§3.3.1, §3.2).
- **Q7 is #765.** Confirmed 3 of 3 with a matching control: replay diverges when a resolver draws from the land's RNG.
- **Public API changes** (§8, for the maintainer once rev 3 is GO):
  - **K2:** none. The rev 2 break is withdrawn; the scoped emitter and the admission path are package or runtime.
  - **K6:** `CanJoin`'s signature (#588).

## 1. Goal and scope

#700 moves `LandKeeper`'s turns onto `TurnCore`. Keeper inputs become machine inputs. Work outside turns becomes keyed requests whose results come back as inputs. Each CLAUDE.md reentrancy exception that names the keeper ends on that model, or is stated as staying with its own issue.

**In scope.**
- Live keepers (`mode == .live`): every entry and every turn kind.
- The sync follow-ups and the failure mailbox.
- The action, join, leave, initialize and destroy resolvers.
- The debug freeze and the land-stop drain.
- The #695 rebind and teardown tests as acceptance tests (§6.1).
- The CLAUDE.md reentrancy section, updated in the slice that ends each exception.

**Out of scope.**
- **Replay** (#612, parked by the maintainer; #550 is folded into it). Re-evaluation keepers keep today's non-turn path, sharing the turn bodies (§3.10). #745 and #756 bind #612, not #700 (§3.10).
- **The tick and sync loops as core timers**: #762 (Q3).
- **The shared RNG** (#765): #700 leaves it where it is.
- **Not keeper code:** the reevaluation monitor land's tick (#387 PR 2).
- **Separate issues:** #744, #752, and the adapter's B-slices (#546 B1–B6).

**Prerequisites.**

| Prerequisite | State on 2026-11-22 |
|---|---|
| #546 L2 slices (L2a–L2d-3) | merged; L2d-3 is #746 |
| Coalesced follow-ups and quiescence wait (#702) | merged as #719 |
| One continuation job (#723) | merged as #734 |
| Post lane, now the mailbox (#725) | merged as #738. Names: `Mail`, `post`, `takeMail`, `handleMail`, `TurnMailbox` |
| Lifecycle handler shapes (#593) | merged as #751. The join and resolver items are open; #700 takes them (K5, K6) |
| Core gaps (§7) | G1 #758 and G2 #759 block K2. G3 #760 is checked before K2's A/B is read. G9 #763 and G10 #764 are optional (before-release) |

## 2. The keeper today, in short

- **No turn core.** LK doesn't import `SwiftStateTurns`. LK:768–774 calls the three sync follow-up slots "TurnCore's request-per-key shape (#700)… kept by hand".
- **A turn is a synchronous actor function.** `runTickTurn` LK:4679, `runInputTurn` LK:5675, `runSyncOnlyTurn` LK:5056 and `settleTurn` LK:1629 have no `await` between apply and outputs.
  - Every live keeper routes through them (`routesThroughTurn`, LK:735).
  - The sync phase runs in the turn when the port shares the keeper's executor (`syncsInTurn`, LK:742).
  - The adapter adopts the keeper's executor (TA:105) and calls back with `assumeIsolated`.
- **One input queue.** `pendingItems` LK:372 holds actions, client events, lifecycle items, server inputs, the shutdown and the land failure. Everything applies through `applyInputs` LK:3917.
- **Work outside turns is a `Task` that calls an actor method, which re-checks by hand:**
  - action jobs: LK:2289, LK:2336, `validateDelivery` LK:2211;
  - join: LK:1866–2057, which writes `players` between awaits;
  - leave: LK:2619–2741, which writes `players` before the OnLeave await;
  - initialize: LK:1073, LK:1252;
  - destroy handlers: LK:5986;
  - the three sync follow-ups: LK:5089, LK:5117, LK:5270;
  - the freeze loop LK:1531 and the drain LK:5896.
- **Waiters are continuations:**
  - tickless turn waiters (`awaitInputTurn` LK:5603), resumed after the record (`resumeInputTurnWaiters` LK:5728);
  - action result waits (`awaitActionResult` LK:2466);
  - the freeze waiters;
  - `shutdownTurnWaiters` LK:5555.
- **Hand-rolled core features:**
  - `GenerationTable` for the sync binding (LK:5147);
  - `EpochCounter` for entry generations (LK:360);
  - `SingleFlight` for `forceShutdown` (LK:2774);
  - the requested-sync-work counter and waiters (LK:5304–5357);
  - `LandFailureMailbox` (#732).
- **References reached from turns:**
  - the `OutputCollector` class, captured by every `LandContext` (LK:396, LK:3335);
  - the recorder, whose order is reserved synchronously by `ReevaluationSubmissionTracker` (ReevaluationRecorderService.swift:17);
  - the port;
  - `services`, including per-player overrides (LK:1951, LK:3328–3330) and `DeterministicRngService`, a locked class (#765).

## 3. Design

### 3.1 What the core holds (Q2 decided: no world)

`TurnCore.init` requires `M: PlainData`. The core holds the model, which is the machine, and the machine's `Behavior` (#768), an immutable value fixed at init and read by every step. There is no world (rev 4's G1, #758, on hold). Every reference gets a narrower home outside the core.

**The model (`KeeperModel`, `@PlainData`).**
- **Counters:** `nextTickId`, `lastCommittedTickId`, the input sequence counter (today in `OutputCollector`), the pass ordinal, `BindingID`, `EntryID`, `FreezeID`, the job sequence.
- **Flags:** `isDraining`, `shutdownRequested`, `didInitialize`, `inTurnSyncDue`, `pendingFold`, the terminal failure.
- **Loop state:** the next tick deadline and the loop epoch (§3.9).
- **Membership:** the pending queue's order index, the membership ids with each entry's `EntryID`.
- **Waiting callers:** action-job bookkeeping (sequence, `EntryID`, the result wait's `InputID` once it steps, the job's `RequestID`), and every other `InputID` a caller waits on (§6.2).
- **Freeze, follow-ups, work:** the freeze generation and held counts, the follow-up binding marks, the in-flight work counts.
- **What rev 4 put in the world** (rev 5): the land's `State`, the admitted queue and the entry facts. Each is `PlainData` after PlainData P3, P4 and K1a: `State` by P4; a queued item's payload as bytes and its decoded value, whose protocol refines `PlainData` (P3, §3.11); entry facts as `@PlainData` `PlayerSession` without `services`. Where each crosses out of a step is the same as rev 4's table below, and a copy is taken in the step, or a `borrowing` read in `core.read`.

**The world (rev 4; withdrawn in rev 5, kept as the record of what crosses out).**

The world is lent mutably to steps and read-only to `core.read` between steps. It is not lent to `flush`, `perform` or effects, which get snapshots. It is not part of any core record (Code-1).

| Value | What it is | Where it crosses out | Snapshot contract |
|---|---|---|---|
| `State` | the land's state tree | resolvers (`ResolverContext.currentState`), adapter reads (`currentStateLocated`), the in-turn sync phase | a copy taken in the step, or a `borrowing` read in `core.read` and in the sync phase |
| the admitted queue | pending items with `AnyCodable` payloads | resolvers (the action payload), the record draft | copied into the effect or draft in the step |
| entry facts | each player's `PlayerSession` without `services` (ids, device, metadata) | join and leave resolvers, adapter reads | copied in the step |

- **The value rule is documented, not proven** (Review). `SyncValueSemantics.validate` (#464, SyncRegistration.swift:89) checks a land's `State` at registration, with known limits:
  - it skips `@Internal` fields, which may hold a class by design;
  - it can miss a reference in an enum case after the first, or in a collection that is empty when it looks.
- **Payloads and resolver outputs.** `AnyCodable` payloads and resolver outputs can wrap anything.
- **The rule stated in the docs of `StateNodeProtocol`, `ResolverOutput` and the payload protocols:**
  - a value that reaches the world must not share a mutable reference with anything outside it;
  - a class held anyway (an `@Internal` field, for one) is shared by the snapshots taken from it, as it is today.
- **No runtime check:** it would cost on every step.

**References: each to a narrower home.**

| Today | Home | Slice |
|---|---|---|
| `OutputCollector` (LK:396), captured by every `LandContext` | **The sequence counter** goes to the model. **A turn's events** are staged in the step and reach `turn.emit` after its last checkpoint (§3.6). **The scoped emitter** is a runtime scope (Code-1 (3)). It covers all three of `LandContext`'s output closures: emit, request sync, and request broadcast-only sync (LandContext.swift:150–156). Each holds its step's scope, a lock-protected open flag that the step closes when it ends. A call after that, including from a task that outlives the step, reads the closed flag under the lock and is dropped and counted, asserted in debug, like `emit` to a dead key (Turn.swift:265). A call while the step runs is on the keeper's executor and stages into the step. `LandContext` stays a public `Sendable` struct, so this is no public change. **Each handler's context** gets a fresh scope per step. **`AfterFinalize`** (LK:5943–5951) runs after the drain as an effect, with its own context whose scope is already closed: its emits are dropped and counted. K7 first pins today's behavior with a test | K2 (counter, staging, emitter); K7 (AfterFinalize) |
| Recorder | **A turn's record draft** is an output. `flush` hands drafts to the recorder's serial sink in step order: `drainProducts` flushes after each step (TurnActor.swift:897, Code-1), which is the order `ReevaluationSubmissionTracker` reserves today. **A caller that waits for the record** waits on a request completed when the sink has taken its draft. Its reply comes from that completion step (§3.4), so replies wait for the record submission | K2 |
| Port (`LandKeeperTransport`) | **A Sendable binding token** (Code-1 (2)): the port reference plus its `BindingID`. **The token travels** in the inputs, queries and effects that need the port: a keeper entry attaches the current one, and a follow-up's gate effect carries it (#702 §5). **The step** checks the token's `BindingID` against the model's, then calls the port's synchronous in-turn methods directly. No port call reaches back into the keeper (§3.7), so nothing else is needed. **The actor keeps the current token** for attaching. It is written only by `flush`, from the `.bind` step's output | K2 |
| `services` | **Land services:** a `LandConfig` `let`. **Per-player overrides** (LK:1951, LK:3328–3330): `LiveLandTurns` stores a table keyed by `(PlayerID, EntryID)`. `flush` writes it from the join step's output, and removes the entry from the leave step's output. The leave step reads the outgoing override before its output deletes it, and puts it in the OnLeave resolver's effect, so the resolver sees the same services as today. A step reads an override through the input that names the entry: the keeper's entry attaches the overrides it reads from the table, and the step checks the `EntryID`. **Lifecycle items** (OnJoin, OnLeave applied in a later tick) carry the `EntryID`, and their apply step gets the overrides through the tick's input: the driver's entry attaches the overrides for the entries whose items are ready. **Effects** get services explicitly in the effect value | K2 |

**Q2 (decided: no world).** `PlainData` covers `State`, payloads and entry facts after all (`2026-11-22-plaindata-all-the-way.md`), so the world isn't needed. The land definition, handlers and `LandConfig` are `Behavior` (#768). The value rule above becomes a compile-time check instead of a documented one.

**The shared RNG (#765).** `DeterministicRngService` is a reference in `services`, drawn by handlers in steps and reachable by resolvers off the actor. #765 decides its fix. #700's K1 census lists it, and K2 doesn't move it.

**K1b's census** (draft in Appendix A). Every stored field of `LandKeeper` gets a home: the model, `Behavior` (the land definition and `LandConfig`), a binding token, the per-player services table, an output, or the K2–K7 replacement list (Tasks and continuations, §3.4, §4). There is no world home. A field that fits nowhere is a finding for Review. The census also checks the model's type: `KeeperModel` is `@PlainData`, so a field that isn't plain doesn't compile.

### 3.2 Keys, the result slot, and cancellation (MF4, MF-a, MF-b)

`Turn.start`'s rule (Turn.swift:47–51): an input that arrives while a key isn't live steps under the next generation, so use a fresh key per binding. Every key that ends and comes back is keyed by an id from the model.

| Key | Lifetime | What it scopes |
|---|---|---|
| `.land` | started at init, `endAll` at the end of the drain | record-wait requests, destroy-handler requests, OnLeave's resolver requests, and the jobs of actions whose sender has no entry |
| `.initialization` | started once at init, ended when initialization finishes or fails | the OnInitialize resolver request (K5), with its deadline |
| `.entry(PlayerID, EntryID)` | started on join with a new `EntryID`; a rejoin ends the old key and starts a new one; ended on leave | that entry's CanJoin and OnJoin resolvers, and its action jobs' requests. Ending the entry closes them, which replaces `cancelActionJobs(ofEntryGeneration:)` LK:2500 |
| `.syncBinding(BindingID)` | `setTransport(port)` ends the old key and starts one with a new `BindingID`; `setTransport(nil)` ends it; the teardown is `endAll` | the follow-up slots (§3.5) |
| `.freeze(FreezeID)` | started by each `debugFreeze` with a new id; ended by resume, shutdown or timeout | the freeze's timeout timer (K7) |

**Abandonment replies** follow today's rejections:
- a job closed by its entry's end replies `LandInputRejection.senderSuperseded` (LK:2158, LK:2223), as today;
- a job closed by the land closing replies `landClosed`.

**OnLeave's resolvers run under `.land`.** The leave ends the entry's key in its own step, and OnLeave's work must outlive that.

**The result slot (MF-a).** Today's `actionSlots` (LK:2251–2257) is kept as a table on the core: the outcome (today an `AnyCodable` or an error) and the waiter's `InputID`, both in the model (rev 5). The outcome's plain form is K1b's census call, per the PlainData plan §3.3: the encoded response bytes, or a response protocol that refines `PlainData`. Its rules, each a K2 test:

| Rule | Today | On the core |
|---|---|---|
| One slot per sequence, created at admission, before `.pending` returns | LK:2312, in `startActionJob`, before `submitAction` returns | the admission step creates it, then answers `.pending(seq)` |
| It holds one terminal outcome or one waiter | `ActionSlot { result, waiter }` | the outcome and the waiter's `InputID` in the model |
| An outcome that arrives before the wait is kept | `fillActionSlot` stores it when no waiter (LK:2446–2460) | the step that fills it stores it; the wait's step replies at once and removes the slot |
| Consumed once | removed when the waiter is resumed or the stored result is read | removed by the step that replies |
| A second wait, or a wait for a sequence with no job | `ActionResultUnavailable` (LK:2473–2476) | the wait's step replies `ActionResultUnavailable` |
| A wait after `endAll` | — | refused with `ActionResultUnavailable`: the drain answers every waiting caller (§6.2) and drops the stored outcomes before `endAll`, and the closed core refuses the wait |

The steps that fill a slot are: the delivery step (tick land), the applying turn's record completion (tickless), a rejection at delivery, the entry-end and drain sweeps below, and a cancellation.

**Cancelling an admitted job: a synchronous token** (MF4, route (a)).

Today's guarantee, from `awaitActionResult`'s cancellation handler (LK:2466–2495): "once `cancel()` returns, a completion that hasn't run yet won't deliver." That handler sets `callerCancelled` and cancels the worker, with no actor hop.

`JobCancellation` is a small `@unchecked Sendable` class with a lock and three states: **open**, **cancelled**, **sealed**. It also holds the worker's task once attached.

| Step | What happens |
|---|---|
| Admission | First `Task.isCancelled`: a cancelled caller gets `CancellationError` at intake, and no job starts (LK:3000–3001). Then the keeper's entry allocates the token and submits `query(.admitAction(…, token))`. The admission step refuses a token already cancelled, creates the slot, and starts the job's request with the token in its effect |
| The worker | `perform` runs the resolvers in a child `Task` that it hands to the token (`token.attach(task)`), then awaits it. Attaching to a token that isn't open cancels the task at once |
| The caller's `cancel()` | Called from the result wait's `onCancel`, and before the wait if the caller is already cancelled. Synchronous: under the lock, an open token becomes cancelled and its task is cancelled. A sealed token is left as it is. No hop |
| Delivery | The `.actionResolved(seq, token, result)` step calls `token.seal()`, which under the lock turns an open token sealed and reports whether it was open. Open: the outcome is delivered into the slot. Cancelled: nothing is delivered, and the slot gets `CancellationError`. So once `cancel()` returns, a completion that hasn't stepped won't deliver: the guarantee holds without G10 |
| Entry end (MF-b) | The step that ends `.entry(pid, eid)` (a leave, or a rejoin) sweeps the entry's jobs, as `cancelActionJobs(ofEntryGeneration:)` does today (LK:2500–2529). For each job whose slot has no outcome yet: `token.cancelByKeeper()` seals the token, whether it was open or already cancelled by its caller, and cancels the worker's task; the slot gets the delivery checks' rejection (`senderSuperseded`), as today. A token its caller cancelled whose worker hasn't returned yet has no outcome, so it is swept the same way and gets `senderSuperseded`, as `cancelActionJobs` gives today (LK:2513–2529); the later delivery step finds it sealed and does nothing. Ending the key then abandons the request; its `handleAbandoned` finds the slot filled and does nothing |
| The drain (MF-b) | The same sweep over every job, before `endAll`, as `cancelAllActionJobs` does today; the slot gets the rejection the delivery checks give while draining |
| The result wait | `awaitActionResult` is `sendAndWait(.awaitResult(seq), .ignoresCancel)` inside `withTaskCancellationHandler`. Its step records its own `InputID` (`turn.input`) under the slot, so the cancel side never needs an `InputID`. If the slot has its outcome, it replies at once |

**The seal (MF-b).** Every step that fills a slot seals the token in the same step. A `cancel()` after that (after delivery, after the entry ended, after the drain) finds the token sealed and changes nothing, so the stored outcome can't change.

A job cancelled by its caller still replies when its worker returns: the request completes, and the delivery step finds the token cancelled. A resolver that ignores cancellation keeps the caller waiting until it returns, as today. G10 (#764) would let the core deliver the cancellation itself, but K2 doesn't need it.

### 3.3 Inputs: each entry keeps its contract (MF2)

A `query` is a synchronous step whose answer returns at once. It can't register a reply waiter, because `Turn.reply` answers only a `sendAndWait`'s `InputID`. So:
- a query is used only where today's caller gets its answer at intake;
- `sendAndWait` is used only where today's caller already waits for application or a result.

| Entry | Today's contract | Machine input | Reply |
|---|---|---|---|
| Action, no resolvers, tick land | empty ACK at intake (LK:3049–3051) | `query(.admitAction)` | the answer: `.completed(empty)` or the refusal |
| Action, no resolvers, tickless | waits for the applying turn and its response (LK:3047) | `sendAndWait(.action)` | from the applying turn's record-wait completion |
| Action **with resolvers**, either land kind | **two-phase**: `.pending(sequence:)` at intake (LK:3023), then the adapter releases its inbound chain (TA:5382–5404); the result from a separate `awaitActionResult` | admission: `query(.admitAction(…, token))`; result: `sendAndWait(.awaitResult(seq))` (§3.2) | admission: `.pending(sequence:)`. Result, tick land: from the `.actionResolved` step, at delivery, before the tick. Result, tickless: from the applying turn's record-wait completion |
| Client event, tick land | returns after intake | `query(.admitClientEvent)` | the answer, or the thrown refusal |
| Client event, tickless | waits for application; throws the handler's error (LK:3166–3178) | `sendAndWait(.clientEvent)` | from the applying turn's record-wait completion: success or the handler's error |
| Server input (`submitServerInput` LK:3198; `ServerInputSubmitter.submit`, which is async "from any task", ServerInput.swift:61–79; a turn's requested work submits later, LK:3306–3312) | `.accepted`/`.refused` at intake. While frozen, accepted at once and held (LK:3246–3253). An initialization failure answers `.refused(.draining)` (LK:3203–3207) | `query(.admitServerInput)` from the caller's task. That includes the work a turn requested, which submits from its own task. It waits at the initialization barrier only, never at the freeze barrier (§3.3.1) | the answer. While frozen: `.accepted(sequence:)`, with the input held in the model's held list |
| Join, tick land | waits for admission | `sendAndWait(.join)` | from the admission step (K2: the last of today's segments; K6: the one validate-and-apply step) |
| Join, tickless | waits for admission, and for application when admission doesn't complete in-turn (LK:2037–2056) | `sendAndWait(.join)` | from the admission step when it completes in-turn; otherwise from the applying turn's record-wait completion |
| Leave, tick land | returns once OnLeave is queued | `sendAndWait(.leave)` | from the step that queues OnLeave |
| Leave, tickless | waits for application (LK:2733–2737) | `sendAndWait(.leave)` | from the applying turn's record-wait completion |
| `stepTickOnce` LK:3456 | waits for the tick | `sendAndWait(.tickDue(...))` | from the tick's record-wait completion |
| Tick and sync loop wakes | Tasks calling actor methods | `send(.tickDue(scheduled, loopEpoch))`, `send(.syncDue(scheduled, loopEpoch))` (§3.9) | — |
| `syncTurnNow` LK:5249, `syncTurnTicket` LK:5235, `settleTurn` LK:1629: synchronous, from the adapter, outside a keeper step | a synchronous answer | `query(.syncTurnNow(token, reason, ticket))`, `query(.syncTurnTicket)`, `query(.settle(token, fence))` | the answer |
| `setTransport` LK:484 | synchronous | `send(.bind(token?))`, control | — |
| `debugFreeze` LK:1531 / `debugResume` LK:1562 | waits / synchronous | `sendAndWait(.freeze(FreezeID, timeout))` / `send(.resume)` | freeze: from the settle step or the timeout (K7) |
| `forceShutdown` LK:2761 | waits for the drain | `sendAndWait(.shutdown)`, control | after the drain's last step. A second call joins the reply list, replacing `SingleFlight` |
| `notePendingFailure` LK:575 (nonisolated) | set-once box | mail `.landFailure(f)` (K4, §3.6) | — |

**Results that come back as inputs:** `.actionResolved`, `.joinResolved`, `.leaveResolved`, `.initializeResolved`, `.destroyHandlerResolved`, `.recordTaken`, `.drainFinished`.

#### 3.3.1 Entry barriers, and no intake holds (MF5, Code-1 (1), MF-c)

A query steps directly. `stepAnswer` (TurnCore.swift:532) checks only borrows, and `close()` lists queries as still stepping. So a query bypasses holds, the queue and `close`. A hold that parks `sendAndWait` intakes would therefore let a query intake overtake them, which today's single `pendingItems` FIFO forbids.

**So #700 puts no hold on intake.** Every intake kind, query or `sendAndWait`, passes the entry barriers before it submits:
- **Initialization** (LK:1088–1107):
  - the entry reads `didInitialize` and the initialization failure through `core.read`, which costs no step;
  - if initialization hasn't finished, the entry waits on `sendAndWait(.awaitInitialized)`, which the initialize step or the failure replies;
  - a failure is thrown to the caller, as today; a server input is answered `.refused(.draining)` instead (LK:3203–3207).
- **The freeze, on tickless lands** (LK:1681–1689):
  - the entry reads the frozen flag through `core.read`;
  - if frozen, it waits on `sendAndWait(.awaitResume)`, and re-checks after the wake, as today.

**Server input is exempt from the freeze barrier** (MF-c), as today (LK:3246–3253):
- the admission step takes its sequence and charges the in-flight cap (`serverInputsInFlight`), then, if frozen, appends it to the held list and answers `.accepted(sequence:)`;
- the resume step queues the held inputs first, in submission order, and only then answers the frozen client intake's `.awaitResume` waiters (LK:1567–1574). So a held server input keeps its place ahead of the client inputs that waited;
- the drain drops the held inputs and uncharges the cap (LK:3287–3290).

**Order: the same as today.**
- No intake is ever parked by a hold, so a query can't overtake a `sendAndWait` intake that a hold parked.
- A `send` queues only while a batch runs, and a keeper entry never runs inside a batch. So an intake that passes the barriers steps when its entry submits it.
- Callers woken from a barrier resume in executor order, and a fresh call can pass them before they resubmit. That is true today too (the continuations at LK:1088–1107 and LK:1681–1689), and #700 doesn't change it.
- A test interleaves query intakes and `sendAndWait` intakes that wait at no barrier, with replies held, and checks that the sequence numbers follow the call order.

**K5** makes initialization a request under `.initialization`, with `RESOLVER_INIT_TIMEOUT_MS` as its deadline (Code-1 (4); the deadline today's OnInitialize resolvers already have, ResolverDeadline.swift:17: default 30 s, 0 disables it, and then the request has no deadline, as today). Its abandonment fails the initialization, and the step answers the barrier's waiters with the failure. Intake doesn't hold on it: the barrier stays.

**K7** keeps the freeze barrier as well. It reads and waits only, outside steps, and mutates no keeper state, so it isn't an exception to the turn rule. Code-1 found the freeze expressible today as a holding request. G9's cleaner shape is a holding request with no effect (#763). Neither is needed while intake takes no holds.

**Tick lands** keep today's rule: inputs queue, and a frozen tick doesn't run.

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
| Action resolvers | a `Task` per job; `completeAction` re-checks the job, the entry generation and the caller's cancellation | `turn.request(.resolveAction(snapshot, services, token), for: .entry(pid, eid))`, or `for: .land` when the sender has no entry. Started in the admission step. The completion `.actionResolved` checks the token, then delivers. A closed request runs `handleAbandoned`: `senderSuperseded` or `landClosed` (§3.2) | K2: `run` with today's checks in the handler; K5: `request` |
| CanJoin / OnJoin resolvers | awaited inside `join` | requests under `.entry(pid, eid)`; a rejoin ends the old key and closes them, replacing the generation checks at LK:2016, LK:5853 | K2: `run`; K6: `request` |
| OnLeave resolvers | awaited inside `leave` | a request under `.land`, carrying the leaving `EntryID`: the leave's step ends the entry's key | K2: `run`; K6: `request` |
| The old session's kick on a duplicate login | `try await leave(...)` LK:1937 | in the join's step: the membership change, then the old entry's OnLeave as a request under `.land` (#588) | K6 |
| OnInitialize resolvers | awaited in `performInitialization` LK:1297, then a direct write LK:1339 | a request under `.initialization` with the init deadline. `.initializeResolved` validates and applies (#593's two phases) in its step; abandonment fails the initialization | K5 |
| Destroy handlers | awaited in order in the drain | one request at a time under `.land`: each `.destroyHandlerResolved` step launches the next. `queue(behind:)` orders inputs, not effects | K7 |
| Waiting for the record | `await submitTurnRecord` LK:5019, then the waiters resume | the step outputs the draft (§3.1) and requests `.awaitRecordTaken(ticket)` under `.land`. `.recordTaken` is the completion of the ordered recorder call: the request's `perform` awaits the submission task that `enqueueRecorderSubmission` returned (LK:5019–5023), whose order was reserved in the step. The waiters' replies come from that completion step; its abandonment (only at `endAll`) replies `landClosed`. `reply(after:)` isn't used, because it publishes the staged reply on abandonment too | K2 |
| Sync follow-ups (three slots) | Tasks with binding marks | #702 plan §5 (§3.5) | K3 |
| The in-turn sync phase | already synchronous | unchanged; the step calls the port through the binding token (§3.1) | K2 |

- **Resolvers reach no keeper data.** A resolver gets `ResolverContext`: a state snapshot and `services`, with no emit and no sync request (ResolverContext.swift:37–95). As an off-actor request it reaches no keeper data, apart from #765's RNG.
- **Cost.** A core `request` is about 13.1k instructions over direct (#624). Actions with resolvers already create a `Task` and hop twice today. Actions without resolvers make no request. K5's A/B decides, and a regression is fixed in the core (#621 item 3).

### 3.5 Sync follow-ups: #702 plan §5, with fresh binding keys

#702 §5 is adopted, with `.syncBinding(BindingID)` per bind (§3.2).

- **Slots.**
  - `.drainRetry` is `.afterWork(.waitForWriterDrain(token), deadline:)`, with the Sendable binding token (§3.1) in the effect;
  - `.joinSync` and `.afterTurn` are `.afterBatch`.
- **The writer gate's `perform` returns `nil`.** Its only job is to make the retry due, so there is no `.writerDrained` input, and a stale drain never steps.
- **The follow-up step does the retry**, with #702's checks in order: `mode == .live`, `failure == nil`, `!isDraining`, then the token's `BindingID` against the model and the port's `runsSyncPhaseInTurn(of:)` (§3.10). The join-sync step re-checks `transportHasJoinsAwaitingSync`.
- **`syncTurnNow`'s order** is kept: accept the token, then consume, then run the phase. A stale ticket returns `.skipped` and consumes nothing.
- **Counters** go where #702 §5.4 places them. `.keptEvents` moves to the machine.
- **Waits.** `waitForRequestedSyncTurnsForTesting` becomes `waitForQuiescence(.followUps, of: .syncBinding(current))`. The requested-sync-work counter and its waiters (LK:5304–5357) are deleted.
- **One intended order change.** Join-sync and after-turn follow-ups armed by one commit run in arm order, not as two Tasks. K3's PR body states it, and the harness row `join-during-writer-backlog` shows whether any golden moves.

### 3.6 The failure mail and staging: #725 plan §4

- **The mailbox.** `LandFailureMailbox` becomes the core's mailbox, typed `TurnMailbox<LandReport>?` from `core.mailbox`, with capacity 1. `notePendingFailure` becomes `post(.landFailure(f))`.
- **The first applied failure is terminal.** Capacity 1 is full until taken, and a post to a full mailbox is refused and counted. The step that takes the first failure sets the model's failure; every later report, taken or refused, leaves it unchanged. A test posts twice around a take.
- **Checkpoints.** Each of today's reads becomes a `turn.takeMail()` checkpoint (post-lane plan §4.1):

| Turn kind | Checkpoints |
|---|---|
| any | the driver's pre-step check |
| initialize | after `finishApply`, even with no `OnInitialize` |
| tick | after apply and the handler, then before `runTurnOutputs` |
| tickless input | after `takePassOrdinal`, before `if failure != nil`, and before the outputs |
| sync-only | the start of the step |
| settle | the start of the step; returns `.failed(f)` |

- **Staging.** A turn's events, record drafts and replies are staged in the step. The last checkpoint comes before anything publishes:
  - before `turn.emit` and `turn.reply`;
  - before the synchronous port call that sends frames (`runSyncPhaseInTurn` publishes directly). #716's "no `emit` before `finishApply`" alone doesn't cover the port.

  A failure found at a checkpoint drops what is staged, and the callers get `landClosed`.
- **Removed:**
  - `submitLandFailure` and `.failureSubmit`;
  - the adapter's awaited submit in `failOutsideTurn` (TA:5656). The adapter keeps `post` and the gate close.
- **The record's shape change** (post-lane §4.2) goes in K4's PR body, with a pinning test: two inputs queued, a post, then the turn. The record holds the failure first, and both inputs are refused.
- **The core's recording stays off.** `onMailTaken` is never set (§3.10).

### 3.7 Port calls inside the keeper's step (MF3)

**What the step calls on the port, synchronously:**
- `runSyncPhaseInTurn` (LKT:180, public `LandKeeperTransport`);
- `runSettlePhaseInTurn` (LKT:309, package `LandKeeperSettlePort`, LKT:305);
- the admission hooks `admitJoiningSession` (LKT:116, public) and `refusesResolvedJoin` (LKT:130, public);
- `noteJoinInputsConsumed`, `noteInTurnSyncFold`, `noteInTurnJoinSyncTick`.

**What reaches back into the keeper during those calls**, which on the core would step it inside a step and trap:

| Port call | Calls back into the keeper? | On the core |
|---|---|---|
| `runSyncPhaseInTurn` | **No.** The adapter collects the phase's sync-stream drafts and returns them in `InTurnSyncOutput.syncStream` (TA:2839–2853, TA:3825–3832). The recording flag comes in as `recording:` | unchanged; no signature change |
| `runSettlePhaseInTurn` | No, the same way | unchanged |
| `admitJoiningSession` → `supersedeSessions` (TA:1550, TA:1908) → `recordSyncStreamClear` (TA:3951) | **Yes.** It reads `keeperRecordsSyncStream()` (TA:3800, `keeper.assumeIsolated`) and calls `submitSyncStream` (TA:3956) | **A package path.** A requirement on the package `LandKeeperSettlePort`: `admitJoiningSessionInStep(…, recordsSyncStream: Bool) -> (JoinAdmission, [SyncStreamDraft])`. The step passes the flag from the model, since `core.read` can't be called in a step. The drafts come back for the step to stage. The adapter implements it, and the public `admitJoiningSession` keeps its signature for other conformers. The keeper calls the package path when the port conforms, as `TransportAdapter` does. A port that doesn't conform records no sync stream, so the public call has nothing to call back |

K2's audit greps the adapter for every `keeper.assumeIsolated` and lists each with the path that reaches it, so a callback missed here is found before the cut-over.

**Adapter calls into the keeper from outside a step:**

| Call | On the core |
|---|---|
| `recordSyncStream` from a standalone initial sync (`.legacyCycle`, TA:3827–3829) | an entry, `send(.syncStreamDraft(...))`: steps at once when idle and keeps its order with the turns |
| `recordSyncStreamClear(outsideTurn: true)` from a disconnect (TA:1336) | the same entry |
| `syncTurnNow`, `syncTurnTicket` (TA:3128, 3181, 3197, 3201, 3489, 3494, 5099, 6374), `settleTurn` (TA:6223) | `query` (§3.3). K2 lists each site with the reason it can't run inside a keeper step |
| Reads: `entrySession` (TA:1458), `currentStateLocated` (TA:5212), `isLive`, `isDraining`, `recordsSyncStream` (TA:3801) and the like | `core.read` on the model: a borrow, not a step |
| `joinReportingAdmission`, `leave`, `handleClientEvent`, `submitAction`/`awaitActionResult`, `requestJoinSyncTurn`, `debugFreeze`, `debugResume`, `notePendingFailure` | the entries in §3.3 |

**The debug check** covers only synchronous step entries: `query`, and the keeper's synchronous entries that step. Called from inside a keeper step, they trap with the entry's name. `send` from a step legally queues, so it is never asserted.

### 3.8 The per-message path: cost

Client events and actions are per-message. #546's decision budgets about +100 instructions per message for the core.
- **The query intake's cost is not established.** read1's 13 instructions (#624) measure a `core.read`, not a query step, which takes the mailbox and an ordinal. K2's full A/B measures it on tick actions with and without resolvers, and on tickless client events (§5).
- **Waits.** Actions with resolvers (the result wait) and every tickless input waited on a continuation and now wait on a reply waiter (`call` is about 2.9k instructions over direct). One waiter replaces one continuation.
- **If K2's A/B puts the query intake over budget,** the fix goes in the core: G5 (#761), or a cheaper admission step. Not a keeper shortcut. Nothing blocks K2 until then.

### 3.9 Ticks and the sync loop (timers: #762)

- **The loop Tasks stay drivers that only send typed inputs** (LK:3402–3441, LK:5739):
  - they send `.tickDue(scheduled, loopEpoch)` and `.syncDue(scheduled, loopEpoch)`;
  - `scheduled` is the instant the driver slept for;
  - `loopEpoch` is the model's, read when the loop was configured;
  - the tick driver's entry attaches the binding token and the per-player overrides its step needs (§3.1).
- **The `.tickDue` step:**
  - writes the next tick deadline into the model, for the fold rule (LK:787);
  - rejects a stale `loopEpoch` (after a stop or a reconfigure) in its step.
- **The fold rule** moves into the `.syncDue` step.
- **The loops as core timers are #762.** That needs #753 and timer support on #759's clock. Its semantics are #762's:
  - the first fire is the phase offset plus one interval;
  - the scheduled instant rides in the input.

  K9 doesn't wait for #762.

### 3.10 The type layout, and re-evaluation keepers until #612 (Q1)

A public `LandKeeper<State>` can't conform to `TurnActor` only when `mode == .live`. `TurnActor` and `scripts/lint-turns.sh` also require a stored `let core` and a stored `nonisolated let mailbox` (the `let-mailbox` rule).

```swift
public actor LandKeeper<State: StateNodeProtocol> {          // public facade; its API unchanged
    nonisolated let owner: KeeperOwner<State>                  // fixed at init by mode
    nonisolated public var unownedExecutor: UnownedSerialExecutor { owner.executor }
}
package enum KeeperOwner<State: StateNodeProtocol>: Sendable {
    case live(LiveLandTurns<State>)
    case replay(ReplayLandOwner<State>)
}
package actor LiveLandTurns<State: StateNodeProtocol>: TurnActor {
    let core: TurnCore<KeeperMachine<State>>                   // the model; Behavior = definition + config (#768)
    nonisolated let mailbox: TurnMailbox<LandReport>?          // core.mailbox
    let config: LandConfig<State>
    nonisolated(unsafe) weak var facade: LandKeeper<State>?    // set once in LandKeeper.init; passed to runsSyncPhaseInTurn(of:)
    // perform, flush; besides these, only the current binding token and the per-player
    // services table, both written from flush (§3.1)
}
package final class ReplayLandOwner<State: StateNodeProtocol> {  // isolated to the replay executor; no core
    var model: KeeperModel<State>
    let behavior: KeeperBehavior<State>                         // the same value the live core gets
}
```

- **The executor.**
  - On a live keeper, `LandKeeper` adopts `LiveLandTurns`' executor. The adapter adopts the keeper's (TA:105), so all three share one serial executor. `live.assumeIsolated` passes on it (Code-1).
  - The facade forwards with `live.assumeIsolated { … }`.
  - A replay keeper adopts the executor of a small replay actor.
  - `LiveLandTurns` is created first in `LandKeeper.init`, so `owner` is set without `self`.
- **Identity** (MF-d). Two comparisons today: the adapter's `isAttached(to:)` (TA:109–111), and the keeper's `port.runsSyncPhaseInTurn(of: self)` (LK:5218).
  - `runsSyncPhaseInTurn(of keeper: AnyObject)` is a public requirement (LKT:94). An outside conformer may compare `===` with the keeper it holds, and a `false` at attach stops the process. So the step passes the `LandKeeper` facade, as today. `LiveLandTurns` holds the facade weakly (the facade owns it), set once at the end of `LandKeeper.init`, before any entry can step. A step that finds it `nil` (the facade is gone) treats the port as not attached. Implementation note (Review's GO): it is `nonisolated(unsafe) weak var`, set once at the end of `LandKeeper.init`; a debug assertion in the step entry checks that it was set before the first step (a set-once flag, separate from the weak reference, so a facade that is gone isn't mistaken for one never set).
  - The adapter holds the facade, as today (TA:103–108), and compares it.
  - So every public witness sees the same object as today, and §8's "no public change" holds.
- **The lint.** `lint-turns.sh` approves the facade's forwarding boundary: a facade that holds a `TurnActor` and forwards through `assumeIsolated` to its entries. K2 adds that rule with a fixture.
- **The turn bodies (K1b)** are synchronous functions over `(inout KeeperModel<State>, KeeperBehavior<State>, …)` (rev 5: no world).
  - The live path calls them inside steps.
  - The replay path calls them from `ReplayLandOwner`'s path, which awaits the source between them, as today: the CLAUDE.md exception "until #612".
- **The invariant: replay never steps a core.** It is pinned by ownership: `ReplayLandOwner` has no core, and the replay path never reaches `LiveLandTurns`. Since `ReplayLandOwner` is package-only, the pin lives inside the package: a `@testable` test reflects a constructed `ReplayLandOwner` with `Mirror` and fails if any stored property's type is a `TurnCore` or a `TurnActor`. It is a runtime check, not a compile-time one: it catches a stored core, not a core reached through a reference.
- **A replay keeper's transport.** It can have one (`.transportAndSink`: `flushOutputs` sends to it, LK:692–710), and the invariant doesn't depend on it not having one. That transport is never a sync binding: `routesThroughTurn` and `syncsInTurn` are false for re-evaluation keepers (LK:735, LK:742).
- **`notePendingFailure` on a replay keeper** (Code-1 (6)) is a no-op, as today (LK:576 returns for non-live keepers): the replay owner has no mailbox.
- **Q1 (maintainer).**
  - (a) A core that lends itself mutably while never stepped.
  - (b) Replay ticks as core inputs: #612's redesign.
  - **(c), recommended:** the layout above.
- **#745 and #756** concern the core's own record and replay. #700 uses neither:
  - live keepers record through the keeper's recorder, and `onMailTaken` is never set;
  - replay owns no core.

  So #756's "before any adopter records mail" holds, and #745's limitation never meets a keeper path. Both stay with #612.
  - The keeper's decisions from `core.read` (the initialization barrier, the frozen flag, the adapter's reads) are a reader #756 §3.3 names: under #612's replay, such a reader runs #756's pump first, or #612 owns that ordering.
- **Later, at #546 B** (Code-1): once the adapter has its own core on the shared executor, a keeper step that calls the adapter's in-turn methods nests two cores. That needs its own rule then; #700 doesn't create it.

### 3.11 K1a: the record keeps raw bytes (PlainData Q4, slice P5)

The maintainer's decision (PlainData plan Q4):
- keep the raw bytes per action;
- the encoding goes once in the record header (`ReevaluationRecordMetadata`), not per entry;
- the bytes are base64 inside the JSON record.

K1a does that, and it is what lets a queued item become `PlainData` without an `AnyCodable` (`base: Any`) in it.

**Today** (main 5e8bc586):
- `PendingActionItem` (LK:196) holds:
  - `source: any PayloadDecodingSource` (an `AnyCodable` tree, or a `MessagePackValue`);
  - `decoded: (any ActionPayload)?`, nil for an item from the public init;
  - `actionType: any ActionPayload.Type`, a metatype.
- Its public `action: AnyCodable` is built from the source on each read.
- A client event item holds `AnyClientEvent`, with the same `source`.
- The record writes `actionItem.action`, the tree, as `ReevaluationRecordedAction.payload: AnyCodable` (LK:3592). The log stores the tree as canonical MessagePack.
- Replay builds the item from that tree with the public init (LK:4361), so it decodes at apply, through the JSON round trip. `RecordPayloadSource`, with its `integralFloats` allowance for the JSON view, decodes recorded events in the monitor's replay frames (ReevaluationReplayFrame.swift:202) and resolver outputs (LandContext.swift:315).

**After K1a:**

| Item | Holds | Record |
|---|---|---|
| Action | `decoded: any ActionPayload`, always set: intake decodes, and replay decodes when it builds the item. `bytes: Data`, the payload in the record's encoding | `payload` becomes the bytes (MessagePack `bin`; base64 in the JSON view). `typeIdentifier` is unchanged (`String(describing:)` of the type) |
| Client event | the same pair | the same |
| Server input | `any ServerInputPayload` (P3 types it) | P3 keeps today's tree. K1a writes the typed value encoded in the record's encoding: a server input has no wire bytes |
| Resolver outputs | `[String: any ResolverOutput]` (P3: `PlainData`) | unchanged: Q4 covers payloads only |

**`actionType`** stops being stored. It becomes a computed `type(of: decoded)`, so the public property stays. The handler lookup by it is unchanged in K1a; K2's brief turns it into a dictionary keyed by wire name (Main). The PlainData plan's "the metatype becomes a name" is met this way, without storing a name: nothing in the model is a metatype.

**What the bytes are.** The record's encoding is one of two: `json` (the `json` and `opcodeJsonArray` transports, whose payloads are JSON text) or `messagepack`. The rule: the bytes the record keeps decode, with the decoder the live run used, to the value the live run decoded. Per source:
- **JSON** (`AnyCodablePayloadSource`). The live decode encodes the tree with a default `JSONEncoder` and decodes that data (`InboundPayloadDecoding.decode`, InboundPayloadDecoding.swift:13–15). Those bytes can't be the record's (rev 5.1): the encoder doesn't sort keys, and an `AnyCodable` object's keys come out in hash-seed order, so the bytes vary per process. Instead, a recording land encodes the tree once more, for the record, with one fixed configuration: `outputFormatting = [.sortedKeys, .withoutEscapingSlashes]` and the default number strategies, in one place (`RecordPayloadEncoding.canonicalJSON`). This is **canonical JSON**:
  - **Key order** is sorted.
  - **Numbers and escapes** come from one encoder configuration, so the form is fixed within a toolchain and platform. The goldens are recorded in the pinned 6.2.4 image. Bytes across platforms aren't claimed: replay's correctness rests on decode equality, not on bytes.
  - **Decode equality:** the tree is the one the live run decoded. Its JSON decodes with the same `JSONDecoder` to the same value, since key order doesn't change what `Decodable` reads from an object with distinct keys.
  - **The live round trip is unchanged.** So the live decode can't change, and a land that doesn't record pays nothing. A recording JSON land pays one extra encode per input.
  - **A 3.7 payload needs no `integralFloats` allowance:** the JSON view decodes the bytes, not a tree rendered from them.

  Prior art: RFC 8785 (JCS) and RFC 8949 §4.2 (deterministic CBOR) define canonical forms across implementations. Neither is needed here: within one toolchain one encoder configuration is deterministic once keys are sorted. JCS's ECMAScript number form would mean a hand-written serializer. The record log's own MessagePack is already canonical (`CanonicalMessagePack`).
- **MessagePack** (`MessagePackPayloadSource`). The frame decoder has unpacked the payload into a `MessagePackValue`; the client's byte range isn't kept. K1a writes the value packed canonically. Unpacking it gives the same value (a non-finite number is refused at intake by `validateRecordable`), so replay's `MessagePackValueDecoder` decodes the same result. Keeping the client's exact slice needs the frame decoder to keep offsets: **K1-Q2**.
- **A source in the other encoding, or none:** a hand-built `AnyClientEvent`, an item from a test, or a server input. The bytes are the decoded typed value, encoded once in the record's encoding at intake. Nothing was received, so there is nothing to keep.

**Cost.** Only a land that records pays for the bytes (`recordsInputs`, as the tree today, LK:3584). A land that doesn't record keeps `decoded` alone, and its item holds no bytes (`bytes: Data?`). So the hot path of a non-recording land changes by one stored optional. A recording MessagePack land packs once per input, where today it built an `AnyCodable` tree and the log packed that. K1a's A/B tier is small: the default cell and `rows-mp`, with recording on.

**The header.** `ReevaluationRecordMetadata` gains `payloadEncoding: RecordPayloadEncoding` (`json` or `messagepack`), written once. `TransportEncoding` is in SwiftStateTreeTransport and the keeper can't name it. So SwiftStateTree gets the two-case enum, and the transport layer passes it when it creates the land's recorder (`LandManager`, from `NIOLandServerConfiguration.transportEncoding`). A keeper with no transport (tests, the reevaluation runner) uses `messagepack`, the record log's own codec.

**Format version 3.7.**
- A 3.7 record's payloads are bytes in the header's encoding.
- Replay of a 3.6 record: **K1-Q1**.
- A newer reader refuses nothing older than `minimumSupported` that it can read today. The JSON view renders a 3.6 tree as before and a 3.7 payload as base64.

**Public API (K1a):**
- `ReevaluationRecordedAction.payload` and `ReevaluationRecordedClientEvent.payload` become `Data` (were `AnyCodable`);
- `ReevaluationRecordMetadata` gains `payloadEncoding`;
- `PendingActionItem.action: AnyCodable` is removed. Nothing outside the keeper reads it. A view that needs a tree decodes the bytes;
- `PendingActionItem`'s public init takes the typed action (`some ActionPayload`) instead of `AnyCodable` and a metatype;
- `actionType` stays, computed;
- `AnyClientEvent.payload` stays, built from `decoded` or the source as today. The keeper's item no longer holds the `AnyClientEvent`.

Each change is listed in K1a's PR. There's no deprecation step: there are no external users (as #593).

**What P3 must leave for K1a.** P3 makes the payload protocols, server inputs and resolver outputs `PlainData`. It must not change:
- `PendingActionItem`'s stored shape, `PendingClientEventItem`'s, or `PayloadDecodingSource` (K1a replaces the source with bytes);
- the record's entry types, `ReevaluationRecordMetadata`, `ReevaluationRecordVersion` or the log's payload form. P3's typed server input is recorded as today's tree (`AnyCodable` of the typed value), so P3 doesn't bump the format.

It must keep:
- `InboundPayloadDecoding`'s JSON round trip producing its `Data` in one place, so K1a can keep it;
- `_payloadWireName` on every payload type.

If P3 takes up #616 (a live input's payload checked once, by its frame's decode), it tells K1a which source types remain.

**Replay's decode failures.** Replay now decodes when it builds the item, not at apply. Today a recorded payload that doesn't decode throws in `applyPendingItem` before its record (LK:3571, before LK:3584). `applyInputs` (LK:3941–3959) then gives its caller the failure, leaves it out of `rejected` (only recorded inputs are listed) and logs it. The live/replay comparison sees what follows from that.

A replayed client event that doesn't decode isn't thrown: its handler drops it (LandDefinition.swift:414–423). A `PayloadNesting.TooDeep` is also logged and counted (`noteDroppedClientEvent`, #362); any other error is dropped silently.

K1a keeps both reports. An item whose bytes don't decode at build time is still queued, with no `decoded` and a plain failure record (rev 5.2):

```swift
@PlainData enum RecordedPayloadDecodeFailure {
    case tooDeep(limit: Int)          // rebuilt as PayloadNesting.TooDeep(limit:)
    case undecodable(String)          // String(describing: error) of the decode's error
}
```

- **The error value isn't kept;** the item stays plain. At apply, `.tooDeep` throws `PayloadNesting.TooDeep(limit:)` again, the same type and value. `.undecodable` throws `RecordedPayloadDecodeError`, whose `description` is the stored text. It is thrown at the same point as today, before the record.
- **Who looks at the error** (checked at 2fdcabf9). Nothing inspects an action's error type in replay:
  - `applyInputs` counts it, logs `String(describing:)` and puts it in `outcomes` (LK:3946–3959);
  - `outcomes` reaches `inputTurnResults` (LK:5713–5717), whose waiters exist only for live callers;
  - the tick replay path takes `.applied` only (LK:4697);
  - in `Sources/`, `DecodingError` is matched only in `TypeToSchemaConverter.swift:540`, which is unrelated.

  The client-event path matches `TooDeep` only, which `.tooDeep` keeps.
- So outcomes, `rejected`, the log line's text, the drop counter and the comparison are unchanged.

`replayPayloadDecodeFailureIsReportedAsBefore` pins today's report on main first, with three recorded inputs:
- an action whose payload has a field of the wrong type: refused, not in `rejected`, and the log line's error text;
- a client event of the same kind: dropped, not counted;
- a client event nested past the limit: dropped and counted once.

K1a keeps it green with 3.7 records whose bytes fail the same way. The test also asserts that the action's thrown error's `description` equals `String(describing:)` of the original `DecodingError`.

**Tests (K1a):**
- **Per encoding** (JSON, opcode JSON, MessagePack), an action and a client event: the recorded bytes decode, with the live decoder, to a value equal to the live `decoded`.
- **`canonicalJSONIsStableAcrossProcesses`:** the same 16-key object, recorded in two child processes (Swift Testing exit tests, each writing its bytes to standard output) with default hashing, gives equal bytes. A one-process check under `SWIFT_DETERMINISTIC_HASHING` can't show it. With 16 keys, two seeds that happen to give the same unsorted order are negligible (1 in 16!).
- **`jsonSourcedItemUnderMessagePackHeaderRecordsTheTypedValue`:** on a land whose header is `messagepack`, an action that arrives through `AnyCodablePayloadSource` is recorded as its typed value's canonical MessagePack. The test checks equality with `CanonicalMessagePack` of the typed value, and inequality with that payload's canonical JSON bytes.
- **An integral float:** a JSON `1` into a `Double` field replays equal without `integralFloats`.
- **A hand-built item and a server input:** recorded in the header's encoding.
- **A non-recording land:** its items hold no bytes. A `Mirror` test fails if `bytes` is set when `recordsInputs` is false.
- **The header:** written once, and read back.
- **3.6 records:** per K1-Q1.

**Mutants:**
- `.sortedKeys` dropped from `canonicalJSON`. Caught by `canonicalJSONIsStableAcrossProcesses`;
- the live round trip's bytes recorded instead of `canonicalJSON`'s (rev 5's design). Caught by the same test;
- the MessagePack bytes are packed non-canonically. Caught by the decode-equality test on an `Int` that fits a smaller width;
- the header is omitted. Caught by the read-back test;
- the record view shows the base64 string (no `recordPayloadAsTree`). Caught by `jsonRecordPayloadComparesAsTreeOffThePinnedToolchain`;
- `.tooDeep` stored as `.undecodable`. Caught by `replayPayloadDecodeFailureIsReportedAsBefore`'s drop counter.

The E2E record/replay runs in three encodings and the game's reevaluation E2E end with 0 mismatches.

**Harness.** The wire frames don't change. Every golden's record changes: the header's new field, the version, and each recorded payload's form.

**Rule `recordPayloadAsTree` (rev 5.2).** The harness compares record bytes only when a golden was recorded with the running toolchain (`checkBytes`, DifferentialHarnessTests.swift:91). Elsewhere it compares the record's decoded view (`DiffRunner.decodedView`, DiffRunner.swift:656). Canonical JSON bytes are stable within a toolchain and platform only. If the view showed a 3.7 payload as its base64 string, a run off the pinned image would report a payload difference that is only a spelling (a number's form, an escape). So the view renders each recorded payload as its tree: the bytes decoded with the header's `payloadEncoding` (JSON parsed, MessagePack unpacked), in the form a 3.6 golden's tree has. The byte comparison on the pinned image still sees the bytes.

`classify-golden-changes.py` compares decoded views, so with that rule a 3.6 → 3.7 golden shows no payload leaf change. Its `recordPayload` class then covers only `metadata.payloadEncoding` appearing and `metadata.version` 3.6 → 3.7, and a changed payload leaf stays `other`. K1a adds the rule and the class in a tool-only commit first. Then:
- the goldens are re-recorded by the recorder script in the pinned image;
- every change classifies as `recordPayload`, with no `other`;
- each cell's difference goes in `ExpectedDifferences.swift` with that cause.

Tests for the rule:
- **`DiffSelfCheckTests.jsonRecordPayloadComparesAsTreeOffThePinnedToolchain`:** two captures whose record bytes differ only in one JSON payload's spelling (`"a\/b"` against `"a/b"`). Byte mode reports `<bytes>` only; decoded-only mode reports nothing. A changed payload value is reported at its field path in both modes.
- **`scripts/classify-golden-changes.py --self-test`** (new, in the tool-only commit): a 3.6 → 3.7 pair of fixture goldens classifies only the two header leaves, as `recordPayload`. A pair whose payload value changed reports `other` and exits 1.

## 4. How each CLAUDE.md exception ends

| Exception (CLAUDE.md) | Code today | Ends in | How |
|---|---|---|---|
| Join/leave resolvers | LK:1866–2057, LK:2619–2741 | K2 (steps), K6 (#588) | Membership changes in a step. CanJoin and OnJoin are requests under `.entry(pid, eid)`, and OnLeave is a request under `.land`. A rejoin ends the old key. CanJoin validates and OnJoin applies in one step, and the old session's leave is in that step. #548's in-turn variant is a test |
| Freeze drain/settle (#129): `debugFreeze` re-checks its generation and registers its waiter after each await | LK:1531–1556 | K7 | `.freeze(FreezeID, timeout)` starts its key, arms the timeout timer and asks for the settle. The caller's reply comes from the settle step or the timer. A newer freeze supersedes the key. No await loop and no hand re-check. The tickless intake barrier stays at the entry (§3.3.1): it reads and waits, and mutates nothing |
| Action-frame bookkeeping after the resolvers (`debugEndWork`, `awaitInputTurn`) | LK:1696, LK:5603 | K2 (the waiter), K5 (`debugEndWork`) | The waiter is a reply (§3.4). In-flight work is the model's count, changed in the admission step and in the result or abandonment step |
| The land-stop drain's post-await bookkeeping (#522) | LK:5896–5964, LK:5970 | K7 | `.drain` captures the land's state in its step: the ticket is `.land`'s generation. Destroy handlers run as chained requests. `.drainFinished` answers every kept waiter (shutdown callers with success, the rest `landClosed`; §6.2), releases through the captured binding token (#698: Q4), then calls `endAll` |
| `LandFailureMailbox` stands in for the core's mailbox (#732) | LandFailureMailbox.swift, LK:565–575 | K4 | §3.6 |
| Re-evaluation keepers' non-turn replay path (#612) | LK:4254–4553 | **stays** until #612 | §3.10 |
| The reevaluation monitor tick (#387) | ReevaluationMonitorLand.swift:28–70 | **stays** until #387 PR 2 | not keeper code |

Not listed in CLAUDE.md, but of the same class, and they end too:
- OnInitialize resolvers followed by a direct write, and `didInitialize` set after an await (LK:1103–1105): K5.
- The tick land's force shutdown, whose shutdown turn writes `nextTickId` before an awaited record (LK:2796–2799): K2.
- `runTick`'s writes before `runTickTurn`: K2, inside the `.tickDue` step.
- `tearDownAfterFailedInitialization` (LK:1173): K5.

## 5. Slices

Each slice is its own PR to `main`, after Review's GO on this plan.

**Every slice runs:**
- `swift test` on both legs;
- `swift test` in `Examples/Demo` and in `Examples/GameDemo`;
- E2E in all three encodings, plus the game E2E with reevaluation (0 mismatch);
- `swift build -c release` and the release filter on the touched suites;
- must-not-compile;
- one mutant per new rule.

**The differential-harness pass** (adapter differential harness, rev 10; 84 cells, all in-turn since L2c):
- byte comparison in the pinned 6.2.4 image;
- `scripts/differential-gate.sh` with `ran + replaced == listed`, `ran > 0`, `compared == run`, `threw == 0`;
- each difference listed in `ExpectedDifferences.swift` (exact, one cell, one use) with its cause, classified by `scripts/classify-golden-changes.py`.

**Host A/B tiers:**
- **full:** #554's five cells plus `nonsync`, ABBA with 5 pairs, and a regression is more than max(0.5 %, 3× spread) on `instructions:u`;
- **small:** 1–2 cells.

A cell this plan needs that doesn't exist yet is added first, in a tool-only commit with a Mac output check.

| Slice | Content | Needs | Harness: allowed differences | Host A/B |
|---|---|---|---|---|
| **K1a** | The record keeps raw bytes (§3.11): queued actions and client events hold bytes plus the decoded value; the header's `payloadEncoding`; format 3.7; `actionType` computed; the public changes in §3.11. A tool-only commit first adds the `recordPayload` class to `classify-golden-changes.py` | PlainData P3 and P4 merged; K1-Q1 to K1-Q3 answered | the record part of every cell, all classified `recordPayload`; frames none | **small**, recording on: the default production cell and `rows-mp` |
| **K1b** | The storage split and its census (§3.1), with no world: `KeeperModel<State>` is `@PlainData` and holds `State`, the queues and entry facts; `KeeperBehavior<State>` holds the definition and `LandConfig`. Turn bodies become synchronous functions over model and behavior. Every multi-await flow's segments become named synchronous functions. No core; behavior unchanged. Replay calls the same bodies | K1a | none | **small**: the default production cell and `rows-mp` |
| **K2** | The cut-over. The layout and identity (§3.10). Every live entry becomes a core entry with its contract (§3.3). The entry barriers, server input's freeze exemption, and no intake holds (§3.3.1). Each K1 segment becomes a step; each await between segments becomes a `turn.run` whose result is an input, with today's checks in the handler. Also: fresh keys, the result slot and the sealed cancellation token (§3.2); record drafts and waits (§3.4); the scoped emitter, the binding token and the per-player services table (§3.1); the admission's package path and the callback audit (§3.7); drivers (§3.9); the lint rule. Follow-ups and the failure box work as today | `Behavior` (#768, merged), G2 #759; G3 #760 checked before the A/B is read | none | **full**, plus three cells: tick actions without resolvers, tick actions with resolvers, tickless client events |
| **K3** | Sync follow-ups on the core (§3.5): the writer gate returns `nil`, and `waitForQuiescence` replaces the hand-rolled waits. The hand-rolled slots and the requested-sync-work waiters are deleted. The #695 acceptance tests are rewritten (§6.1) | K2 | only the arm-order change (§3.5), if a cell shows it | **small**: a host cell with join churn and kept-event follow-up churn |
| **K4** | The failure mail (§3.6): capacity 1, the first applied failure terminal, checkpoints, staging before the port, the record-shape change. `LandFailureMailbox`, `submitLandFailure` and `.failureSubmit` are deleted | K2 | failure rows' record order, if a cell has a post before queued inputs | **small**: the default cell and `rows-mp`. This slice sets the mailbox budget left open by the post-lane plan |
| **K5** | Resolvers as keyed requests. Action jobs go under their entry's key or `.land`: abandonment replaces `validateDelivery`'s checks, and the token is kept. OnInitialize goes under `.initialization` with its deadline, so initialization becomes a turn and its abandonment answers the barrier. `debugEndWork` becomes the model's count | K2 | none | **small**: the default cell and the tick-actions-with-resolvers cell |
| **K6** | Join and leave per #588. CanJoin is `validate` with `ValidateContext` and returns a plan; OnJoin is `apply`; both run in one step. That step also does the stale-join refusal, `maxPlayers` (reconnection exempt), the duplicate-login kick and the draining guard. One refusal form. A refused join is recorded. #548's tests | K5 | join-refusal rows, if the one refusal form changes their bytes | **small**: K3's join-churn cell |
| **K7** | The freeze (#129) and the land-stop drain (#522) on the core (§4). The destroy handlers chained (§3.4). AfterFinalize's context (§3.1). The drain answers every kept waiter before `endAll`. forceShutdown's `SingleFlight` is replaced | K5 | none: the `freeze-resume-*` rows stay byte-identical | **none**: off the measured paths; recorded as a `call` with that reason |
| **K9** | Deletions: the keeper's `GenerationTable`/`EpochCounter`/`SingleFlight` uses; the replaced `HoldPoints` (§6.3); the dead `.live` arms (`flushOutputs` LK:674–691, `runSyncRequests` LK:718, recorder branches at LK:3871, 4523, 4540 and 1404–1413), each first proven unreachable. CLAUDE.md's reentrancy section is rewritten: the keeper exceptions left are #612 and #387 | K1–K7 | none | **Mac output check** |

**Ordering.**
- PlainData P3 and P4, then K1a, then K1b. K1b's census can be drafted (read-only) while K1a is in review.
- K1 doesn't wait on G2.
- K3, K4 and K5 are independent of one another.
- K6 needs K5, and so does K7.
- #762 (timers) follows K2 and doesn't block K9.

**Stop conditions** (#546's decision, applied to the keeper):
- A slice that needs a coordinator-shaped machine API stops, and the outline is redone.
- If K9's deleted scaffolding is smaller than the machine code K2–K7 added, Review revisits.
- A core gap found mid-slice stops the slice. It is reported and fixed in the core, then the slice resumes.

## 6. Tests

### 6.1 #695's acceptance tests, and the latch test (Q5 decided)

| Test | On main | At #700 |
|---|---|---|
| Rebind with a held retry: `olderBindingsRetryDoesNotBlockTheCurrentOne` (`TransportAdapterRequestedSyncTurnTests.swift`) | yes | K3 rewrites it per #702 plan §5.5 (b)–(d). B's follow-up is `.armed` while A's gate waits. A's late gate return steps nothing, checked with a step counter. B delivers stamp 2 while A's writer is held. Its mutant (a keeper-wide slot) still fails it |
| Teardown with an armed retry: `teardownEndsAnArmedRetry` | yes | K3. Slot quiescence after the teardown, **plus** a separate check that A's gate returned after the teardown. Its mutant (the writer teardown not releasing its drain waiters) still fails it |
| Latch window: `syncDuringSettleCycleIsLatched` | no | **Retired, nothing to port.** L2b retired it (#712, ef23c7a7), and L2d deleted the latch slot |

**Acceptance coverage named in its place** (Review, Q5):
- `ordinaryPhaseKeepsTheFrozenDefer` (TransportAdapterDebugFreezeTests:625): K2, K7.
- `freezeIsCheckedBeforeBackPressure` (TransportAdapterRequestedSyncTurnTests:206): K3.
- `eventKeptBySettleArrivesAfterResume` (TransportAdapterPendingEventsAcrossCyclesTests:653): K3, K7.

**New, for a case the migration creates:** a follow-up armed before a freeze and still due at the settle. The settle step runs, and the follow-up steps after it, once, under its binding. K3 adds it, and K7 keeps it green.

**K3 also adds:**
- #702 plan §5.3's stale-lag test;
- #695 round 3's known gap: an older binding's retry, across a teardown that reaches only the new binding's writer, is closed by `endAll` and not left counted.

### 6.2 New tests per slice

Tests force interleavings with holds (`HoldPoints`, `TestGate`, a gated `perform`), never timing, and bound every wait (`withinDeadline`, `withinHangBound`).

| Slice | Tests |
|---|---|
| K1a | §3.11's tests and mutants |
| K1b | **The census:** every stored property of `LandKeeper` has a home (§3.1), checked by `Mirror`, so a new field fails until placed. The RNG is listed (#765). `KeeperModel` is `@PlainData`, so a non-plain field doesn't compile; a must-not-compile snippet pins one (a `KeeperModel`-shaped struct holding an `AnyCodable`) |
| K2 | **Each contract in §3.3:**<br>- the tick ACK without resolvers returns before any tick;<br>- an action with resolvers returns `.pending` at intake on both land kinds, and the adapter's inbound chain moves on before the resolver delivers;<br>- the tick result arrives at delivery, before the tick;<br>- a tickless client event's handler error reaches its caller;<br>- a tickless join that doesn't complete in-turn and a tickless leave each wait for application;<br>- a server input submitted from a turn's requested work, while frozen, returns `.accepted` at once, holds its sequence and its cap, and at the resume is queued before the frozen client intake wakes;<br>- a server input during a failed initialization gets `.refused(.draining)`.<br>**Order:** query and `sendAndWait` intakes that wait at no barrier, interleaved with replies held, keep call order (§3.3.1).<br>**Barriers:** intake before initialization waits on the barrier; an initialization failure reaches every barrier waiter; the freeze barrier re-checks after its wake.<br>**Result slot (§3.2):** an outcome that arrives before the wait is returned by the wait; a second wait and a wait for an unknown sequence get `ActionResultUnavailable`; a wait after `endAll` is refused.<br>**Cancellation:** cancel a job while its resolver is held, then release: nothing delivers, and the caller gets `CancellationError`. Cancel between the request's completion and its delivery step: nothing delivers. A cancelled caller gets `CancellationError` at intake, and no job starts. Each runs with a mutant that drops the token check at delivery.<br>**Entry end and the seal:** a leave while a job's resolver is held cancels the worker (its task sees cancellation) and fills the slot with `senderSuperseded`; the drain does the same for every job. The sweep test also pins a job its caller already cancelled, worker still held: the sweep gives `senderSuperseded`, and releasing the worker changes nothing. A `cancel()` after delivery, after the entry ended and after the drain leaves the stored outcome unchanged; mutant: a token without the seal.<br>**Keys:** a job closed by its entry's end gets `senderSuperseded`; a stale `BindingID` or `EntryID` is refused in its step.<br>**Emitter:** each of the three output closures, called from a Task that outlives its step, is dropped and counted.<br>**Services:** the OnLeave resolver sees the leaving player's override.<br>**Admission:** the supersede clear goes through the package path, not the actor.<br>**Steps:** a query from inside a keeper step traps (debug), and `send` from a step queues.<br>**Waiters:** they resume after the record is taken, with the record request held; an abandoned record wait replies `landClosed`.<br>**Shutdown:** with a tickless action, a result wait, a join waiting for admission, a caller waiting on a record completion and a shutdown caller pending, the drain answers every one before `endAll`: the shutdown callers with success, the others `landClosed`. The core's deinit assertion holds.<br>**Replay:** the `@testable` reflection pin on `ReplayLandOwner`, and `notePendingFailure` on a replay keeper is a no-op |
| K3 | §6.1 |
| K4 | Two inputs queued, a post, then the turn (§3.6). Two posts around a take: the first is terminal. A failure at the last checkpoint publishes nothing to the port. The S1b mutant still fails |
| K5 | An entry leaves while its job's resolver is held: abandonment, `senderSuperseded`, nothing applied. Initialization's resolver is held while a join arrives: the join waits at the barrier, then is admitted. Initialization's deadline passes: the initialization fails, and every barrier waiter gets the failure |
| K6 | #588's checks in one step, each refusing in one form. #548: hold the join's resolver, tear down, release with `.allow`; no membership, slot, joining record or connection generation is left (plus the in-turn variant). A duplicate login's old OnLeave runs under `.land` and isn't closed by the old entry's end |
| K7 | #129's freeze and resume, interleaved with a deferred writer retry held at the former await. A newer freeze supersedes an older one's settle. A `leave` during the destroy handlers is refused. Destroy handlers run in order. `forceShutdown` called twice gives one drain and two replies. AfterFinalize's emit behaves as pinned. Shutdown with a freeze caller pending answers it |

### 6.3 The keeper's hold points

LK:55–82 has 11 points:
- **K2** keeps each point that still exists, now inside a step or a `perform`.
- **K5 and K7** move the points that sat between an await and a write into the effect's `perform`: `.actionComplete`, `.join`, `.leave`, `.drainStart`, `.landFailedTeardown`.
- **K4** deletes `.failureSubmit`.
- **K9** deletes the points with no user.

Each PR lists the tests whose hold moved.

## 7. Turn-core gaps

| # | Gap | Tracked | Blocks |
|---|---|---|---|
| G1 | The world: values only, lent to steps and to `core.read` | **#758**, on hold: Q2 decided no world (rev 5) | nothing |
| G2 | A production `TurnClock`, minimal: `now` and `sleep(until:)` over `safeTaskSleep` | **#759** (foundation; narrowed) | K2 |
| G3 | Step-path specialization for a generic machine from another module: a verification gap until a check shows a compiler problem | **#760** | reading K2's A/B |
| G4 | One sleeper for all deadlines | #753 (#621 item 2) | #762 |
| G5 | `send` returns `Void` | **#761** (before-release) | only if K2's A/B puts the query intake over budget |
| G6 | Effect launch and hop cost | #621 item 3 | only if K5's A/B regresses |
| G7 | The waiter table's cost | #621 item 4 | only if K2's A/B regresses on waiting entries |
| G8 | The mailbox's per-entry budget | post-lane §3.8 open item | K4 sets it |
| G9 | A holding request with no effect, released by `cancel`, its key's end or its deadline (Code-1's shape) | **#763** (before-release) | nothing: #700 puts no hold on intake (§3.3.1) |
| G10 | A caller's cancellation delivered to the machine for a stepped call | **#764** (before-release) | nothing: the token in §3.2 keeps the guarantee |

Not gaps for #700: the core's input recording, `.cancelsCall` in replay, #745 and #756 (§3.10).

## 8. Public API changes

For the maintainer, once rev 3 is GO.

| Slice | Change | Kind |
|---|---|---|
| K1a | `ReevaluationRecordedAction.payload` and `ReevaluationRecordedClientEvent.payload` become `Data`; `ReevaluationRecordMetadata.payloadEncoding` added; `PendingActionItem.action` removed and its public init takes the typed action; `actionType` computed (§3.11) | break |
| K2 | **none public.** Rev 2's `runSyncPhaseInTurn` break is withdrawn: the port already returns its drafts and takes the recording flag (§3.7). The admission clear takes a package path, and `admitJoiningSession` keeps its signature. The scoped emitter is a runtime scope, and `LandContext` keeps its shape (§3.1). The public witness `runsSyncPhaseInTurn(of:)` still receives the `LandKeeper` facade (§3.10, MF-d); this row holds only with that | — |
| K2 | `package`: `syncTurnNow`, `settleTurn` and `syncTurnTicket` become queries; new `LiveLandTurns`, `ReplayLandOwner`, `KeeperOwner`, `JobCancellation`; `admitJoiningSessionInStep` on `LandKeeperSettlePort` | package |
| K6 | `CanJoin` takes `ValidateContext` and returns a plan that `OnJoin` receives (#588, agreed with the maintainer 2026-11-18). K6's PR lists every changed signature. The maintainer confirms there that no deprecation step is needed | break |

**Behavior changes users can see,** each stated in its PR:
- the follow-up arm order (K3);
- the record order of a failure posted before queued inputs (K4);
- the one refusal form for joins (K6);
- an emit from a context kept past its step is dropped and counted (K2), where today it reaches the collector;
- AfterFinalize's emit, if K7 changes what it does today.

## 9. Questions

For the maintainer. Main files each as a decision issue. K1b doesn't depend on Q1 or Q4; K1a depends on K1-Q1 to K1-Q3; K2 depends on Q1.

**Q1. Where does a re-evaluation (replay) keeper keep its state until #612?** (§3.10)

| Option | What it is | K1 | K2 |
|---|---|---|---|
| (a) One core, never stepped in replay | `LandKeeper` itself is the `TurnActor`. A replay keeper keeps a core but only borrows its model mutably, without stepping | the same split | needs a new core API to lend the state mutably outside a step: a core gap, and a second way to change state that the turn rule must allow |
| (b) Replay ticks become core inputs | replay steps the core like live | the same split | pulls #612's redesign (parked) into #700; K2 waits for it |
| **(c) A facade over two owners (recommended)** | `LandKeeper` stays the public type and forwards to a live owner with a core, or to a replay owner with none | the turn bodies become functions over (model, behavior) that both owners call | adds `LiveLandTurns`, `ReplayLandOwner` and a lint rule for the forwarding; the public API is unchanged; #612 later deletes the replay owner |

**Q2. How does the core hold the land's non-plain state?** (§3.1) **Decided (maintainer, 2026-11-22): no world.** Every value the turns change is `PlainData` (`2026-11-22-plaindata-all-the-way.md`); the definition and config are `Behavior` (#768). The options as rev 4 put them:

| Option | What it is | K1 | K2 |
|---|---|---|---|
| **(a) The world in the core (recommended)** | the core holds values that aren't `PlainData` beside the model, lent only to steps and `core.read` (#758) | the census places `State`, the queue and entry facts in the world | needs #758 first; no public change; the value rule is documented |
| (b) `@PlainData` on every land `State` | the compiler checks `State` | the same census | a public break for every land, and `@Internal` fields holding a class are refused. It doesn't cover payloads or entry facts, so #758 is still needed |
| (c) Both | (a) now, and (b) probed in its own issue | as (a) | as (a); the probe reports what (b) would break |

Rev 4 recommended (a). The decision went further than (b): `PlainData` on `State`, payloads, resolver outputs and entry facts, so no world is needed.

**K1-Q1. Replay of a 3.6 record after K1a** (§3.11)

| Option | What it is | Cost |
|---|---|---|
| **(a) Recommended** | `minimumReplayable` becomes 3.7: a 3.6 record is still read (the JSON view, the monitor's listing) but not replayed, as 3.6 did for records without a fingerprint | none; a recording made before K1a is re-recorded to replay |
| (b) | a 3.6 reader keeps building items from the tree (today's public-init path, kept package-only) | a second item builder and its tests, until a later version drops it |

**K1-Q2. MessagePack: the client's exact bytes, or the value packed canonically?** (§3.11)

| Option | What it is | Cost |
|---|---|---|
| **(a) Recommended** | pack the unpacked `MessagePackValue` canonically. The bytes decode to the same value with the live decoder; a client that sent a wider integer than needed is recorded in the narrower form | one canonical pack per recorded input |
| (b) | keep the payload's byte range from the frame | the frame decoder keeps offsets for every payload, recording or not; a copy of the range per recorded input |

**K1-Q3. Client events too?** Q4 named actions. A queued client event holds the same `PayloadDecodingSource` and `AnyCodable`, so it can't be `PlainData` either without the same change.

| Option | What it is |
|---|---|
| **(a) Recommended** | client events get the same pair and the same record form, in K1a |
| (b) | actions only. The client event item then needs another plain form for K1b, such as a `MessagePackValue`-like value tree, and the record keeps two payload forms |

**Q4. When is #698 fixed?** (A teardown can notify a transport other than the one it closed. Production attaches once, so it doesn't happen there today; `setTransport` is public.)

| Option | What it is | K1 | K2 |
|---|---|---|---|
| **(a) In K7 (recommended)** | the drain step captures the binding token and notifies the transport it closed, plus any distinct one bound later; #698 closes with K7 | none | none |
| (b) Now, separately | a small fix on today's code: pass `failLand`'s captured recipient to the destroy notification; K7 then carries it over | none | none; K7 keeps the test green |
| (c) Not supported | refuse `setTransport` once the keeper is failing or draining, and document it | none | the `.bind` step refuses while draining |

Decided:
- **Q3** (Review): the timers are #762.
- **Q5** (Review): the latch test is retired.
- **Q6** (Code-1): the fit read is folded in above.
- **Q7:** filed as #765.
- **Q8:** withdrawn, since there is no `LandKeeperTransport` break.
- **MF4's route** (Main): (a), the token.

## 10. Prior art

- **Elm's `Cmd`/`Msg` and Erlang's `gen_server`** (CLAUDE.md's rule). A step returns work as data, and the result comes back as a message that re-reads current state. §3.4 applies that rule to each await.
- **Monitors and re-entry.** §3.7's trap on a synchronous step entry from inside a step is the monitor's re-entry check. `send` from a step is a message to self, queued as in an actor's mailbox. §3.7 removes the one port call that re-entered by having it return its drafts as data.
- **Cancellation tokens checked at the commit point** (.NET's `CancellationToken`, Go's `context`). §3.2's token is set synchronously by the canceller and read by the step that would deliver, so the decision sits where the effect lands, not in the hop that carries the news.
- **Capabilities over ambient references.** §3.1's binding token names its binding, and the step checks it before use.
- **The strangler fig.** K1 extracts the bodies so the live and replay paths share them, K2 routes the live path through the core, and #612 later removes the replay owner (Q1 (c)).

## Appendix A. K1b's census (draft)

**Status:** a draft, written after rev 5.2; not part of any rev's delta. It is ready for K1a's review and is checked again on K1b's base.

It covers every stored property of `LandKeeper`, from `LK` at main d25ca82d: 123 declarations in the actor body (LK:113–6024), computed properties excluded. Each gets one home.

**Homes:**
- **Model:** `KeeperModel<State>`, `@PlainData`, the core's machine;
- **Behavior:** `KeeperBehavior<State>`, immutable, fixed at init (#768): the definition and `LandConfig`. Sendable, not necessarily `PlainData`;
- **Outside:** held by `LiveLandTurns` or the facade, written only from `flush` or at init (§3.1's reference table);
- **Replay:** `ReplayLandOwner` (Q1 (c));
- **Kn:** replaced in that slice, and kept as today until then.

**PlainData status:**
- *plain*: a `PlainData` type today, or after #772;
- *@PD*: needs `@PlainData` on a named type, which K1b adds;
- *P3*, *P4*, *K1a*: plain once that slice lands;
- *finding*: not plain, and the census proposes a form.

### A.1 Model

| Fields (LK line) | Status | Note |
|---|---|---|
| `state` (357) | P4 | |
| `players` (358) | @PD `InternalPlayerSession` minus `services` | `services` moves Outside (the per-player table, §3.1). `clientID`, `lastSessionID` and `Epoch` are plain once `ClientID`/`SessionID` (P3 or P4) and `Epoch` are |
| `pendingItems` (372), `serverInputsHeldWhileFrozen` (3261) | P3 + P4 + K1a | `PendingItem`'s cases: action and client event (K1a), lifecycle (`resolverOutputs`: P3), server input (P3), shutdown (plain), land failure (@PD `LandFailure`) |
| counters: `stateHashUnavailableTotal` (369), `serverInputsInFlight` (374), `serverInputCapRejections` (377), `syncStreamCounter` (452), `passOrdinal` (460), `foldedSyncs`, `overdueFoldedSyncs`, `lateFoldedSyncs` (751–759), `inTurnDeferredTurns` (766), `recorderSubmissionCount` (812), `inputsSkippedAfterDestroy` (851), `joinSyncTicks` (2122), `supersededSenderRejections` (2128), `actionJobsStarted` (2272), `pendingItemScans` (3531), `requestedSyncWork` (5304), `ticksInFlight` (5364), `nextTickId` (656), `lastCommittedTickId` (662) | plain | `serverInputCapRejections` is counted at intake; in K2 that is the admission query's step (§3.3) |
| flags: `destructionFinished` (514), `transportRecordsFolds` (527), `didInitialize` (643), `inTurnSyncDue` (748), `inputDrainScheduled` (795), `joinSyncWaitsForCommit` (2125), `shutdownRequested` (2778), `hasHeldTransport` (5166), `destroyHandlersStarted` (5383), `shutdownTurnApplied` (5565) | plain | |
| `passInProgress` (463), `appliedTickPhaseOffset`, `appliedSyncPhaseOffset` (3383, 3388) | plain | `Int64?`, `Duration?` |
| `inTurnSyncTurnKind` (454) | @PD `ReevaluationRecordedSyncOutput.TurnKind` | a `String` enum |
| `syncOutputIndexCursor` (457) | finding (tuple) | a `@PlainData` struct `{ observedTickId: Int64?, count: Int }` |
| `entryGenerations` (360) | @PD `EpochCounter`, `Epoch` | K2 replaces it with `EntryID` (§3.2); K9 deletes it |
| `syncBinding` (5170), `inTurnDrainRetryBinding` (779), `joinSyncTurnBinding` (5111) | @PD `Ticket`, `GenerationTable` (Generations.swift:8, :31) | K2's `BindingID` replaces them (§3.5); K9 deletes them |
| `serverInputMaxInFlight` (375) | plain | set at init from the environment, and by a package setter (LK:3298). Behavior if the setter goes; else Model |
| `ticklessJobWork`, `ticklessJobTurns` (2275, 2278) | plain | `Set<Int64>` |
| `filledActionSlotsForAssert`, `…OrderForAssert`, `…NextForAssert` (2282–2284) | plain | debug-only bookkeeping, kept in Model under `#if DEBUG` |
| `initializationFailure` (642) | **finding F1** (`any Error`) | see A.5 |
| `outputCollector` (441), a class | finding: split | `nextSequence`, `checksOverflow`, `sequenceExhausted` and `syncRequestsByTick` (@PD `SyncRequests`) go to Model. `emittedEvents` is staged as `any ServerEventPayload` (P3) with @PD `EventTarget` (§3.6, K2). The class goes |
| `actionJobs` (2256) | split | `item` (K1a), `input`, `completed` and `cancelledByKeeper` go to Model. `ticket` is @PD `Ticket` until K2's keys. `task` → K5. `abandonment` (a class) → K5. `callerCancelled` (a class) → K2's `JobCancellation` (§3.2) |
| `actionSlots` (2256–2257) | **finding F1/F2** | `result` holds `AnyCodable` or `any Error` (A.5). `waiter`, a continuation, → K2's `InputID` (§3.2) |
| `inputTurnResults` (5652) | **finding F1/F2** | the same as `actionSlots.result` |

### A.2 Behavior

| Fields | Status | Note |
|---|---|---|
| `definition` (355) | not plain (handler closures) | the reason Behavior exists (#768) |
| `services` (361) | not plain (references) | §3.1: land services are config. The RNG inside is #765's |
| `logger` (364) | not plain | immutable and Sendable |
| `autoStartLoops`, `enableLoopPhaseOffset`, `enableLiveStateHashRecording` (365–368), `reevaluationOutputMode` (370), `mode` (378), `actualLandID` (473) | plain | `LandConfig`. `actualLandID` is set once at init (#751) |
| `systemPlayerID`, `systemClientID`, `systemSessionID` (955–957) | plain | constants; could be static instead |

### A.3 Outside (LiveLandTurns or the facade)

| Fields | What it becomes |
|---|---|
| `transport` (363), `releasedTransport` (519), `boundSyncRequesterObject` (5173), `pendingSyncTurnAfterTurn` (5268, holds the port) | the binding token and its follow-up (§3.1, §3.5), K2 |
| `reevaluationRecorder` (444), `recorderSubmissions` (809) | the recorder sink; drafts are outputs that `flush` hands on (§3.1), K2 |
| `drainFlag` (544) | a class read `nonisolated` (`isDraining`, `failure`); `flush` publishes into it, K2 |
| `pendingTransportFailure` (565) | `LandFailureMailbox`: K4 deletes it (the core's mailbox) |
| `abandonmentCounter` (2260) | shared with resolver groups, read at intake: Outside, K5 |
| `tickLoopClock` (3400), `tickLoopConfiguredAt` (3387), `nextTickDeadline` (783), `pendingFold` (763, holds an `Instant`) | the loop driver's time. `ContinuousClock.Instant` isn't `PlainData`. K2 writes the next tick deadline into Model on #759's clock (G2, §3.9). `pendingFold`'s flag part is Model already in K1b |

### A.4 Replaced in a slice (K2–K9), with test hooks

| Fields | Slice |
|---|---|
| `tickTask`, `syncTask` (539–540) | K2 drivers (§3.9), then K8 |
| `destroyTask`, `drainTask` (541, 543), `forceShutdownFlight` (2774) | K7 |
| `initializationTask` (639) | K5 (`.initialization` request) |
| continuations: `inputTurnWaiters` (799), `actionJobRemovalWaiters` (2270), `initializationWaits` / `initializationWaitWatchers` (1112–1113), `tickIdleWaiters` (5365), `shutdownTurnWaiters` (5555) | K2: a waiter is an `InputID` in Model, its reply the core's |
| the freeze: `debugFrozen`, `debugHeldInputs`, `debugInFlightWork`, `debugDrainWaiters`, `debugNextWaiterID`, `debugActiveGeneration`, `debugReleasedGeneration` (941–952) | K7 (#129). The counts and generations are plain and go to Model; the continuations go |
| test-only waiters: `drainStartedWaitersForTesting` (595–596), `freezeWaitWatchersForTesting` (2557), `inputDrainIdleWaitersForTesting` (2569), `requestedSyncWorkWaitersForTesting` (5307–5308), `failureWaitersForTesting` (5456–5457) | K2: each becomes a wait on a core outcome or a `HoldPoints` replacement (§6.3); K9 deletes what's left |
| test hooks: `holds` (633), `inTurnProbeForTesting` (822, a closure), `inTurnYieldForTesting` (826), `syncClockForTesting`, `tickClockForTesting` (910, 921) | Outside, on `LiveLandTurns`, test-only; `holds` per §6.3 |
| test counters: `joinSyncRequestTurnsForTesting` (2090), `joinSyncTurnsForTesting` (5113), `requestedSyncTurnsForTesting` (5298) | Model (plain counters, with @PD `SyncTurnReason` as a dictionary key) |

### A.5 Replay

`replayPassObserver` (4116, a closure), `replayFailureEnd` (4122, a tuple), `replayRecordsPassOrdinals`, `replayRecordsRejected` (4125, 4134), `replayRejected` (4142), `recordedPassMismatches` (4194), `replayedInitializeBeforeTickZero`, `replayedInitializeRefusal` (646, 651) go to `ReplayLandOwner` (Q1 (c)). `reevaluationSource` and `reevaluationSink` (466, 469) go there too. None of these has to be plain: the replay owner has no core. `replayFailureEnd` becomes a struct anyway, if it is shared with the turn bodies.

### A.6 Findings for Review

- **F1: errors in the model.** `initializationFailure` (`LandInitializationError.underlying: any Error`), the failure side of `actionSlots.result` and of `inputTurnResults` (`Result<AnyCodable, any Error>`). `any Error` isn't `PlainData`. A handler's error must reach its caller as the same value, since the adapter maps error types to client error codes. Proposal:
  - Model keeps a plain record per failure: an id, a kind and a description;
  - the error value waits in an Outside table keyed by that id, written by `flush` from the step's output and read when the reply is made;
  - the table follows the per-player services table's pattern (§3.1).

  Rev 5.2's `RecordedPayloadDecodeFailure` is the same move for replay: a plain record in the item, with the error rebuilt at apply.
- **F2: action responses.** The success side of `actionSlots.result` and `inputTurnResults` is an `AnyCodable` built from the handler's `ResponsePayload`. The PlainData plan (§3.3) leaves the form to this census. Proposal: hold `any ResponsePayload`, with `ResponsePayload` refining `PlainData`. That is **an addition to P3's scope**: today P3 names action, event and server-input payloads and resolver outputs, not responses. The other option, encoded response bytes, would make the keeper encode, which today is the transport's job.
- **F3: three tuples** (`syncOutputIndexCursor`, `pendingFold`, `replayFailureEnd`) become small structs, since a tuple can't conform.
- **F4: the loop's `ContinuousClock.Instant`s** stay Outside until G2. K1b's census test lists them as an expected exception, so the test passes until K2 moves them.

**K1b's census test** (§6.2) checks this table against the actor's stored properties with `Mirror`: each name must appear in exactly one home. A new field fails until it is placed. `KeeperModel`'s `@PlainData` gives the compile-time half.

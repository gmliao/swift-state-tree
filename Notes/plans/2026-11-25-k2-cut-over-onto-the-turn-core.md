# K2: the keeper's cut-over onto the turn core (#700)

**Status:** draft 7, for Review. It is a small delta on draft 6, answering Review's verdict on it (1 must-fix, 6 should, 3 nits):
- The sentinel now has one route that every step has, `turn.behavior` (§4.2).
- K2-1 pins a core-driven step that carries no binding token (§4.2).
- The shoulds and nits are tracked as the K2-1 PR checklist (§16).
- 2026-11-26: K2-E keeps the sequence counter and `syncRequestsByTick` in the collector; K1b-5's move commit moves them into the model (§4.4, K1b-5 plan D15.3 rev 2.6).

§17 lists the changes. Draft 6 answered Review's NOT GO on draft 5 (3 must-fix, 3 should, 3 nits):
- K2-Q3's recommended option now has a mechanism and a probe (§4.2, P5).
- There is an entry matrix (§4.2).
- Events keep the in-phase batch (§4.4).
- §7.2 is narrowed to what the core stops.
- Review's exclusivity probe is quoted (P6).
- The admission path's callbacks are named (§4.5).

§15 lists the changes. Draft 5 retook §2, §4 and §7 on what landed:
- K1b-4 (#877, at its head e18e70c0, GO on green CI; merge pending): `KeeperModel`, `KeeperBehavior`, `ReplayFields`, the `playerServices` table and the census.
- K1b-5a step 1 (#865, merged as 65cced07): `withTurn`, `TurnOutputs`, the stored `KeeperTurnSide`, `callOut` and the re-entry sentinel.

It also raises one new question, K2-Q3 (§4.2): two re-entry stops exist, and they differ. §14 lists the changes. Line numbers in draft 5 are `LK` at e18e70c0, found by grep, not by the LSP. K2 still starts from K1b-5's end state, and K2-1 re-takes every anchor on its base. Draft 4 added the probes (§12; all four run) for the points that rest on Swift semantics: the machine's conformance, the shared executor, the facade's weak reference and the exclusivity trap. Draft 3 records K2-Q1, decided (a) by the maintainer (2026-11-25), with #855 as its follow-up and #854 (§5, §9). **Not for Review until K1b lands:** K2 starts from K1b-5's end state, and its line numbers, segment names and type names are re-taken on K2's base. Draft 2 takes Review's pre-read of draft 1 (not a verdict): K2-Q2's split, agreed with four conditions, and its §4 notes. It also takes K1b-5 rev 2's shape (each segment returns its await's request) and the `KeeperTurnSide` interface agreed with K1b-5's author for rev 2.1 (§4.5). §10 lists the changes. Draft 1 was read at main 7baba4c4, without the LSP.

**Inputs:**
- the parent plan `2026-11-22-keeper-on-turncore.md` rev 5.8: §3.1–§3.10, §5's K2 row, §6.2's K2 tests, §7 and §8;
- the K2 prep survey `2026-11-25-k2-prep-survey.md`;
- the K1b slice plans: K1b-1 (plain forms), K1b-2 (failure IDs and the side tables), K1b-3 (the land's generator, PR #853), K1b-4 rev 2.5 (`KeeperModel`, `KeeperBehavior`, the `playerServices` table) and its PR #877, K1b-5a rev 3 (the record; code-first as #865), K1b-5 rev 2.2 (the segments' half, K1b-5b: D1–D10);
- the #852 options note `2026-11-25-852-duplicate-login-cap-options.md`.

Nothing here changes a decision in the parent plan. Where this draft adds something, the section says so.

## 1. Goal

After K2, every live keeper runs on a `TurnCore`:
- every keeper entry is a core entry with its contract (parent §3.3);
- every turn is a step, which calls the K1b-5 body;
- every await between K1b-5's named segments is a `turn.run(effect)` whose result comes back as an input, with today's checks in that input's handler.

The keeper's API, the wire bytes and the record bytes don't change (parent §8: no public change in K2).

**Not in K2** (each has its slice): the sync follow-ups (K3), the failure mail (K4), resolvers as keyed requests (K5), join and leave in one step (K6), the freeze and the drain (K7), the deletions (K9). K2 leaves each of those working as it does today, on top of the core.

## 2. What K2 starts from (K1b's end state)

| From | What K2 uses |
|---|---|
| K1b-4 (#877) | `KeeperModel<State>` (`@PlainData`, `KeeperModel.swift`) is the machine's state: 61 fields, plus 3 that exist only in debug. `var state: State` is declared last, so every other field has a fixed offset in the unspecialized keeper. The cloud's count in a release build, over the tick and input functions, with `state` last vs `state` first: 3 vs 12 calls to `KeeperModel`'s metadata accessor, and 36 vs 163 by the job's second count (#877's mutant job). `KeeperBehavior<State>` (`nonisolated let behavior`, LK:428) is the machine's `Behavior` (#768): the definition, the services, the resolver services, the payload decoders, the logger and an internal `KeeperConfig` of 10 settings. `ReplayFields<State>` (LK:407) holds the 11 re-evaluation fields, which become the replay owner's. These stay on the actor: `playerServices` (LK:405), keyed by player and holding `(generation: Epoch, services:)`; `outputCollector` (LK:499, K1b-4's D1, until K2-E); the failure table; the tasks and waiters. `withHandlerStep`'s body takes `inout KeeperModel` once per step and passes `&m.state` to the handler. `KeeperCensusTests` gives every stored field one row, by storage path (`model.x`, `behavior.config.x`, `replay.x`, `actor.x`) |
| K1b-5a step 1 (#865) | `withTurn` and `withTurnSubmitting` (LK:5488, :5506) own one body call each. A body gets `inout KeeperTurnSide` and `inout TurnOutputs`. `TurnOutputs` stages `.submission` and `.action` effects, and `KeeperTurnSide.flush` runs them once, in staging order, before the body's first suspension. `callOut` (LK:5544) flushes before every synchronous call out of the keeper and returns `.answered` or `.refused`. The re-entry sentinel lives on the actor, outside the model and the side: `bodyDepth`, `reentryViolations`, `reentryFailure`, the three gate fields and `lateReentriesApplied`. A guarded entry called during a body changes nothing, closes the output gate and ends the land in that turn (`LandFailure.Kind.keeperReentry`). In step 1 the side holds only the recorder submission tracker. Step 2 gives `withTurn` the model `&model` |
| K1b-5 | The turn bodies as `mutating` methods on `KeeperModel` that take the behavior and `KeeperTurnSide`, and return `TurnOutputs`. Every async flow as named synchronous segments (J1–J4, L1–L3, the action, intake and driver flows). A segment never awaits: it returns its flow's request enum, one case per await, carrying the capture that crosses it, and a driver performs the await |
| K1b-3 | `landRandom` in the model; `withHandlerStep` as a model method |
| K1b-1 | The queued items' plain forms. K1b-Q5 (d): `PendingActionItem` and `PendingClientEventItem`, and their inits, are `package` |
| K1a | Raw payload bytes in the record; `InputOutcome` carried to the adapter |

**K2's first check on its base** (no code): every segment K1b-5 named still exists, and every value it marked **not plain** has a carrier in §4.3. A segment or a crossing that K1b-5 missed stops K2 until K1b-5's plan is amended.

## 3. The layout (parent §3.10)

- `LandKeeper<State>` stays the public actor and becomes a facade over `KeeperOwner`:
  - `.live(LiveLandTurns)`, which holds the `TurnCore<KeeperModel<State>>`;
  - `.replay(ReplayLandOwner)`, which holds a `KeeperModel` and no core.
- **The parent plan's Q1 is decided: (c), the facade** (maintainer, 2026-11-25). `ReplayLandOwner` is temporary: #612 deletes it, and the facade stays.
- **The machine is the model** (survey §1): `extension KeeperModel: TurnMachine`, with `Behavior = KeeperBehavior<State>`. `TurnActor` requires `M: TurnMachine & PlainData`, which K1b-4's `@PlainData` gives.
- **The executor:** the facade adopts `LiveLandTurns`' executor, and the adapter adopts the facade's (TA:113, `unownedExecutor`), so all three share one serial executor. The facade forwards with `live.assumeIsolated { … }`.
- **Identity:** `runsSyncPhaseInTurn(of:)` keeps receiving the facade. `LiveLandTurns` holds it `nonisolated(unsafe) weak`, set once at the end of `LandKeeper.init`, with a set-once flag that the first step asserts.
- **The lint:** `scripts/lint-turns.sh` gets the facade's forwarding rule, with a fixture.

## 4. The machine

### 4.1 Its types (new in this draft; names are proposals)

| Associated type | K2's type | Holds |
|---|---|---|
| `Input` | `KeeperInput` | the entries that `send` or `sendAndWait`: actions (tickless, and the result wait), client events (tickless), join, leave, `.tickDue`, `.syncDue`, `.bind`, `.freeze`, `.resume`, `.shutdown`, `.awaitInitialized`, `.awaitResume`, `.syncStreamDraft`; and the results that come back from `run`: `.joinStepped`, `.leaveStepped`, `.actionResolved`, `.initializeResolved`, `.destroyHandlerResolved`, `.recordTaken`, `.drainFinished` |
| `Query` / `Answer` | `KeeperQuery` / `KeeperAnswer` | the intakes answered at once: `.admitAction`, `.admitClientEvent`, `.admitServerInput`; the adapter's synchronous calls: `.syncTurnNow`, `.syncTurnTicket`, `.settle` |
| `Effect` | `KeeperEffect` | a case per flow that wraps K1b-5's request enum (`.join(JoinRequest)`, `.leave(LeaveRequest)`, …), for the request cases that are I/O (§4.3); plus `.awaitRecordTaken(ticket, results)` |
| `Output` | `KeeperOutput` | record drafts (to the recorder's serial sink), the binding-token and services-table writes (to `LiveLandTurns`' two stored values) |
| `Reply` | `KeeperReply` | each `sendAndWait` entry's answer: `JoinOutcome`, `InputOutcome`, `Void`, and its failure as `any Error`: not only `JoinError` and `LandInputRejection`, but every error a caller gets today (a handler's or `validate`'s throw, `ResolverExecutionError`, the rebuilt decode errors). `Reply` is only `Sendable` (Machine.swift), so it can carry them |
| `Key` | `KeeperKey` | `.land`, `.initialization`, `.entry(PlayerID, EntryID)`, `.syncBinding(BindingID)`, `.freeze(FreezeID)` (parent §3.2). The ids come from today's types, so K2-1 mints no parallel ones: `EntryID` is the entry generation (the `Epoch` in `entryGenerations`, the same key as K1b-4's `playerServices`), and `BindingID` is the sync binding's `GenerationTable` ticket (`SyncTurnTicket`) |
| `Mail` | `Never` in K2 | K4 makes it `LandReport` |
| `FollowUpSlot` | `Never` in K2 | K3 adds the three slots |

`Input` and `Effect` are `Sendable`, not `PlainData` (Machine.swift:10–12). So a non-plain value can cross an await inside an effect and its result input: the model never stores it.

### 4.2 Entries (parent §3.3, unchanged)

Each row of parent §3.3's table becomes one forwarding method on the facade. The table is the contract, and §6.2's K2 tests pin each row. Three notes for the implementation:
- **Re-entry: two stops, one to choose (K2-Q3, new in draft 5).** Two mechanisms stop a re-entry today, and they act differently:
  - **The core's borrow rule** (TurnCore.swift:115–129, `read` at :476–477). A `read` or a `query` inside a step stops the process with a generic message, in release too: "TurnCore: the machine was read from inside its own step" (`read`, TurnCore.swift:477); "TurnCore: query was called from inside a step" (`stepAnswer`, :644); "TurnCore: a step was entered from inside a step" and "… while a read is open" (`enterStep`, :580–581). So does a step inside a step. A `send` made during a step is not a step entry: the core defers it, and it steps after the current step ends.
  - **#865's sentinel.** A guarded entry called during a body changes nothing, closes the output gate, and the land ends in that turn. The process keeps running. The matrix below shows which entries have it today.

  K2-Q3 asks which behavior K2 keeps:
  - (a) keep the sentinel's behavior, through the mechanism below;
  - (b) take the core's stops, and state the change in K2-2's PR.

  Recommended: (a), since the parent plan promises no public change (§8).

  **(a)'s mechanism** (new in draft 6; probe P5):
  1. **Where the predicate comes from.** The core gets a package accessor, `isStepping` (`borrows < 0`). This is a SwiftStateTurns change, additive and package-only, in K2-1. A counter in the facade can't be the predicate: the core also starts steps the facade never sees (timers, deferred sends, mail after K4). `borrows` is `@usableFromInline internal` today (TurnCore.swift:129), and only `borrowStateForTesting` is `package`.
  2. **How the refusing entry records the trip.** A guarded facade entry reads `live.core.isStepping` on the shared executor before it forwards. When the core is stepping:
     - it changes nothing in the model;
     - it adds 1 to a violation count;
     - it writes the failure to the set-once `LandFailureMailbox` (#732);
     - it closes the output gate itself, under #865's recursion guard (`closingGateForReentry`);
     - it returns the entry's refusal result (the matrix below).

     The count, the mailbox and the guard live in a sentinel object outside the model. It is a final class held by `LiveLandTurns` and used on the shared executor only, the same shape as #865's actor fields.

     **How each step reaches it (draft 7; Review's MF on draft 6).** Not through a binding token: a token rides only the inputs that need a port. These steps carry no token:
     - a timer, which steps its stored input (TurnActor.swift:572–577);
     - an effect completion, which steps its returned input (TurnActor.swift:406–425);
     - a query, which runs `answer` with no `KeeperInput`;
     - an abandonment (`handleAbandoned`), which has no input;
     - K4's mail, which is a `MailTurn` (TurnCore.swift:609–651).

     What all of them have is the behavior: `handle`, `handleAbandoned` and `handleLateResult` get a `Turn` with `turn.behavior`, `answer` gets a `Turn`, and `handleMail` gets a `MailTurn` with `MailTurn.behavior` (Machine.swift:27–28, :47–56). So `KeeperBehavior` holds the sentinel as a `let` reference, fixed at `TurnCore.init`.

     This is a stated exception to the behavior contract's advice to keep a behavior to values and functions (Machine.swift:32–35; the compiler doesn't enforce it). The exception is bounded in three ways:
     - the sentinel is used on the shared executor only;
     - its fields are written only by a refusing entry, which changes no model field;
     - a step reads it only to end the land through its own model.

     #773's behavior lint lists it as the one allowed reference field. The other route, a trip count owned by the core and read through `Turn`, would put keeper policy into the core's API, so draft 7 doesn't take it.
  3. **The tokenless step, pinned in K2-1** (draft 7). The test drives a core-driven step whose input carries no binding token: a timer's `.tickDue`, or an effect completion. During the step, a callback reaches a guarded entry, for example through a draft factory or a staged call reached without `callOut`.
     - The step's backstop, which reads the sentinel through `turn.behavior`, ends the land in that same step.
     - The test reads the result after the step (`failure`, `destructionCause`, and the count).

     P5's core-driven case doesn't cover this: its step reads `sentinel` through the same actor helper the facade-entered step uses.
  4. **How the running step sees it.** `callOut` compares the violation count before and after each port call, as #865 does. It does so inside the step. On a change, the step ends the land through its own borrowed model (`self`), before it reads the call's answer. The refusing entry never touches the model. So a refusal changes land state only in the running step, which fits the turn rule.
  5. **The factory guard and the backstop, in order.** Draft factories run inside the step: the step makes the plain entries, as `recordSyncStream` does today, and only the made entries leave as outputs. So a factory that re-enters is refused like a port callback. The step's last action, before it returns its outputs, is the backstop: a count that changed since the step began, but that no `callOut` applied, ends the land there. The core's flush after the step (TurnActor.swift:904) then carries that turn's outputs, with the failure applied. A staged action that re-enters during the core's flush runs after the step, with `borrows` back at 0, so it isn't refused. That matches #865, where actions at a body's end run after the depth drops.

  **The entry matrix.** "Sync callback" means the entry is reached synchronously from a port call during a step. "Awaited" means it is only reached through `await`, as a separate job, so never during a step.

  | Entry | Reached in production | Today, during a body | K2 under (a) |
  |---|---|---|---|
  | `submitSyncStream` | sync callback (TA:3859, the `.legacyCycle` branch; TA:3986, `recordSyncStreamClear`) | refused: nothing recorded, the land ends | refused through `isStepping`, with the entry's name |
  | `recordsSyncStream` (a read) | sync callback (TA:3831, `keeperRecordsSyncStream`) | no refusal: it reads `behavior.config`, the recorder and the transport, and no model field (LK:5435, :807) | a facade read of the same non-model fields, which never reaches `core.read`, so it is answered during a step too. The admission path passes the flag in anyway (§4.5) |
  | `syncTurnNow` | awaited (TA:3158, :3211, :3231, :3524, :5134) | nested: `.skipped`, and the outer turn returns `.landFailed` | the same, through `isStepping` (the tests reach it synchronously) |
  | `syncTurnTicket`, `settleTurn` | awaited (TA:3227, :3519; the freeze settle) | no refusal result | keeps the core's stop: a query inside a step. Unreachable during a step in production; a test pins that |
  | `currentState()`, `playerCount()` | awaited (LandManager:95, :104) | no refusal result | keeps the core's stop (`read`) |
  | the `send` entries (join, leave, actions, events, server inputs) | awaited | not guarded | deferred by the core, as a `send` during a step is |

  **Where the name comes from.** The core's stop is generic. Each guarded facade entry passes its own name to the refusal, as `noteReentry(through:)` does today, and the debug check reports that name. An entry that keeps the core's stop (the rows above) reports the core's generic message. Only an unreachable path ends up there.
- **Queries can't wait.** A query is used only where today's caller gets its answer at intake (the tick ACK, the two-phase action's `.pending`, the server input's `.accepted`).
- **Barriers, not holds** (parent §3.3.1). The initialization and freeze barriers read the model through `core.read` and wait on `sendAndWait(.awaitInitialized)` / `.awaitResume`. No intake is parked by a hold, so a query can't overtake a parked `sendAndWait`.
- **The debug check** is the matrix's refusal. A guarded entry called during a step is refused with its name and counted, and a normal test reads the count, so a mutant aimed at the refusal is killed without a crash. A crash is left only for the core's own stop, on the rows that keep it. A mutant aimed there runs in the cloud, one test case per process (K1b-2's lesson).

### 4.3 Segments become steps; awaits become `run` (the core of K2)

For each flow, K1b-5's segment returns its request. `handle` maps it, and the result input's handler calls the next segment with (capture, result). The segments don't change: K2-1's `handle` calls the very segment methods the keeper's driver calls, not copies.

K1b-5's request cases are of three kinds, and K2 maps each kind differently:
- **I/O** (`.runCanJoinResolvers`, `.kick`, `.runOnJoinResolvers`, `.runOnLeaveResolvers`, `.startJob`, and the initialization's and drain's resolvers): `turn.run(KeeperEffect.<flow>(request))`. The effect's `perform` does the await off the actor and returns the result input.
- **Barriers** (`.awaitInitialization`, `.waitWhileFrozen`): the entry's `inputPolicy` waits for the barrier (§4.2, parent §3.3.1). Not effects.
- **Reply waits** (`.awaitInputTurn`, `.done`): `.done` is the reply. `.awaitInputTurn` is the `sendAndWait` reply, answered in `.recordTaken`'s step.

| Flow | Awaits that become `run` | The result input, and its check |
|---|---|---|
| Join (J1–J4) | CanJoin's resolvers; the kick (`leave`); OnJoin's resolvers | `.joinStepped(stage, ticket, result)`: the entry generation, `isDraining`, and the stale-join refusal, as today |
| Leave (L1–L3) | OnLeave's resolvers | `.leaveStepped(ticket, result)`: `isDraining`, the drop metric |
| Action jobs | the job's resolvers (one `run` per job; K5 makes it a keyed `request`) | `.actionResolved(seq, token, result)`: the job, the entry generation, the sealed token (parent §3.2) |
| Initialization | OnInitialize's resolvers | `.initializeResolved`; K5 adds the key and the deadline |
| Tickless turns | the record submit, then the waiters | `.recordTaken(ticket, results)`: the turn's results, `[seq: Result<InputOutcome, any Error>]`, ride in `.awaitRecordTaken`'s effect and come back in this input, and the waiters' replies come from this step (parent §3.4). So K1b-2's failure table is used only when nobody waits (its S1: nothing is stored when a waiter exists), and its K2 holder note (keyed by `RequestID`) needs no extra table. No K1b-2 change |
| The drain | the destroy handlers | `.destroyHandlerResolved`, one at a time; K7 keys them |

**What crosses, and how** (K1b-5 §3's "not plain" marks):
- `LandServices` (the per-player overrides): attached to the input by the entry or the driver that names the player (parent §3.1), and from there into the effect. Writes to the table are outputs (§4.5).
- The resolver's `LandContext`: built in the step, carried by the effect. Only its outputs come back, as `[String: HeldResolverOutput]`, which is plain after K1b-1.
- `State` for the resolver: a copy taken in the step (parent §3.1).

**The join's kick is a nested flow.** J2 runs the kick as a `run` of the leave flow's own effect. The leave's steps (L1 runs inside J2's step; its OnLeave await is J2's `run`) then hand back to J3. This is the window #852 is about (§7.1).

### 4.4 Outputs (survey §3; parent §3.1, §3.6)

**In its own PR, K2-E, between K2-1 and K2-2, on today's keeper** (Review's condition 2; §6). It is a per-handler-call scope, the same shape as K1b-3's step RNG service, bound in `withHandlerStep`. One type, `StepScope`, can hold both the RNG service and the emitter scope.
- **The sequence counter** (`nextSequence`, `checksOverflow`, `sequenceExhausted`) and `syncRequestsByTick` stay in `OutputCollector` in K2-E. They move into the model in K1b-5's move commit (K1b-5 plan D15.3, rev 2.6), which ends K1b-4's D1. Their takes sit on the intake, join and leave lines that K1b-5 rewrites, so moving them in K2-E would collide with it. **The invariant that keeps the numbering unchanged meanwhile:** the scope stages each event unnumbered, under its lock, and when the step takes the staged events (on the keeper, after the handler returns) it numbers them from the collector in staging order and appends them to the collector's list, which is where today's emit numbers and appends each one. The numbers are the ones today's emits take, because nothing else can take a number or append an event between a handler's first emit and the take: the handler is synchronous, handler calls don't nest, and `ServerInputSubmitter.submit` is async. Numbering at the take, not at the emit, also keeps the collector off any thread but the keeper's: an emit from a `Task` the handler started touches only the scope.
- **The scoped emitter:** each handler call gets a per-step scope (a lock-protected open flag and the staged list). `LandContext`'s three output closures capture the scope, not the model. When the handler returns, the step takes the staged events and closes the scope. A call after that is dropped and counted, asserted in debug. That is a visible behavior change, stated in K2's PR (parent §8).
- **Where the events go: today's route, not `turn.emit`** (draft 6; Review's MF3). Today an eventful tick or input turn hands its events to the in-turn sync phase, `runTurnOutputs(events:)` (LK:5137) → `runSyncPhaseInTurn(events:)`, ahead of the sync plan, in one call. Only the sync-only turn passes `events: []` (LK:5884). If K2 sent events through `turn.emit`, they would go out after the step, after that turn's frames, so the order would change. So inside a step:
  - the events still ride the in-phase batch, through the binding token's direct call (§4.5), on every path that runs the phase;
  - a path with no phase, which has no bound in-turn transport, keeps today's legacy flush (`outputCollector`'s list, LK:730);
  - `turn.emit` carries only the record entries and the services-table and token writes (§4.1's `KeeperOutput`), never events.
- **Record drafts** are outputs. `flush` hands them to the recorder's serial sink in step order (TurnActor.swift:904, the flush call in `drainProducts` (:897), after each step).
- **The in-turn sync phase** stays inside the step and calls the port through the binding token (parent §3.7).

### 4.5 Ports, tokens and the services table (parent §3.1, §3.7)

- **The binding token** (the port plus its `BindingID`) is attached by the entries that need the port. The step checks the `BindingID` against the model's, then calls the port's synchronous in-turn methods.
- **What #865 landed, and how K2 maps it.**
  - `KeeperTurnSide` is a struct stored on the actor, borrowed `inout` by one body call (`withTurn`). In step 1 it holds only the recorder submission tracker.
  - The bodies stage into `TurnOutputs`, and `callOut` flushes before each port call.
  - K2-1's `handle` builds the same pair per step: a step-local side, and a `TurnOutputs` the step returns. The core's `flush` (TurnActor.swift:904, after each step) then runs what `KeeperTurnSide.flush` runs today. A `callOut` inside a step can't flush through the core, because the step hasn't returned. So K2-1 keeps `callOut`'s own flush of the step-local outputs, and the order at each port call stays as #865 has it. This is new in draft 5. K2-1's differential (§6) compares the two paths' submission traces (`ReevaluationSubmissionTracker`'s trace, #865).
- **`KeeperTurnSide` in a step.** A core step gets only the model (`self`), `turn` (the behavior, which holds no mutable reference, plus `emit` and `run`) and the input. So K2 can't hand a body the actor's `&turnSide`. K1b-5 rev 2.1 makes `KeeperTurnSide` an interface of methods: reads are methods, and every write is staged in `TurnOutputs`. K2-1's `handle` builds a step-local side from the input and a staging buffer, and calls the same bodies. Each method's route:

| `KeeperTurnSide` method | K1b-5 (on the actor) | K2 (in a step) |
|---|---|---|
| `services(for:generation:)`; inserts and removals staged | the actor's `playerServices` (K1b-4: written in the same segment as each insert, rollback, removal and clear of `model.players`; K1b-5 D10 moves it into the side) | reads from the overrides on the input; writes are outputs that `flush` applies to `LiveLandTurns`' table |
| `markFailedFirst(_:) -> Bool` | `drainFlag.setFailed` | a model flag decides; the atomic set is staged |
| `closeOutputs(for:)` | the transport | **direct**, on the binding token: the in-turn sync phase sends frames during the step and emits flush after it, so a staged close would let a later frame of the same step out before the gate closes. A direct call closes it at its place in the turn, as `failLand` does today |
| `syncNowInTurn(…)` | the transport | **direct**, on the binding token: it returns frames to the body mid-turn |
| `takeEmittedEvents`, `takeSyncRequest`, `readPosition` | the collector | the scoped emitter (K2-E) |
| `takePendingFold(now:)` | the actor's `pendingFold`; `now` read by the driver right before the body | the fold and `now` on `.tickDue`'s input |
| `takePendingTransportFailure()` | the actor's field | as on the actor until K4's mail |
| `requestFollowUpSyncTurn(reason:)`, staged | `pendingSyncTurnAfterTurn` | as staged until K3's slot |
| `noteReplayRejected(sequence:)` | the replay group; nothing on a live keeper | the replay owner's side only |
| `recordFailure(_:) -> FailureID` | the ID from the model's counter, the value staged | the same; the value rides in the effect and the reply (§4.3) |
| `probe(_:)` | the test hook | the test hook; it must not call back into the keeper |

- **The admission clear** takes a package path, `admitJoiningSessionInStep(…, recordsSyncStream:) -> (JoinAdmission, [SyncStreamDraft])`, so no port call reaches back into the keeper during a step.
- **The callback audit, in K2-1 or before it** (Review's condition 3), not inside K2-2: grep the adapter for every `keeper.assumeIsolated` and list each with the path that reaches it. At e18e70c0 there are three: TA:3831, :3859 and :3986. A callback a step can reach must have a row in §4.2's matrix with a refusal or a step-local answer; one without such a row is a stop, and it moves the plan before the big PR is written. The audit also covers code the core runs during its own accesses, which the borrow rule doesn't stop (§7.2): `KeeperKey`'s `==` and `hash(into:)`, and the deinits of what the core drops from `KeeperInput` and `KeeperKey` payloads (`LandServices`, the binding token, draft factories, carried errors). None of them may call into the keeper.
- **The admission path** (draft 6 names it, should 3). The keeper's admission of a joining session (`admitJoiningInTurn`, LK:2259) calls the adapter's `admitJoiningSessionIsolated` (TA:1984). On a superseded session, that runs `applySessionPerPlayerPolicy` (TA:1571) → `supersedeSessions` (TA:1935) → `recordSyncStreamClear` (TA:1966 → :3981). That is two callbacks into the keeper: the recording-flag read (`keeperRecordsSyncStream`, TA:3831) and the draft submission (`submitSyncStream`, TA:3986). Inside a step both would be refused, and every recorded supersede would end the land (K1b-5 plan rev 2.2 D2, on branch `docs/k1b5-plan-rev-2.2` at 8e65c987; the plan file on main at 19fe61e5 is still rev 2.1). The package path `admitJoiningSessionInStep(…, recordsSyncStream:) -> (JoinAdmission, [SyncStreamDraft])` avoids both: the step passes the flag in, and the clear's drafts come back as the call's result, which the step records itself.
  - The `.legacyCycle` branch (TA:3858–3859) submits outside any keeper step. It is reached from `_syncStateForNewPlayer` (TA:5228): the adapter's initial sync reads `await keeper.currentStateLocated()` (TA:5247), and after that hop it commits in its own segment. The keeper isn't running a step there, so the submission goes in as an ordinary entry.
  - The disconnect's clear, `recordSyncStreamClear(outsideTurn: true)` (TA:1358, in `handleDisconnectQueued` after `await keeper.leave`), is outside a step for the same reason.
- **The per-player services table** lives on `LiveLandTurns`, keyed by `(PlayerID, EntryID)`, the same key as K1b-4's `playerServices` (`EntryID` is the entry generation). K1b-4 stores it as `[PlayerID: (generation: Epoch, services: LandServices)]`, one entry per player. An entry whose generation differs from the player's current entry is never read, and a removal checks the generation. `LiveLandTurns` keeps that shape. The 10 write sites K1b-4 lists (#877's audit) become the outputs `flush` applies. `KeeperPlayerServicesTests` pins them, and K2-2 runs it against the facade unchanged. `flush` writes it from the join step's output and removes it on the leave step's output. The queued OnLeave handler's lookup at apply time (K1b-4 §3.3) reads the current entry's overrides, which the tick driver attaches to `.tickDue`'s input.

### 4.6 Drivers and the result slot

- **The tick and sync loop Tasks** only `send(.tickDue(scheduled, loopEpoch))` and `.syncDue(…)` (parent §3.9). The `.tickDue` step rejects a stale epoch. #762 makes them core timers later.
- **The result slot and `JobCancellation`** (parent §3.2): the slot table in the model, the token's three states, the seal in every step that fills a slot.

## 5. The Behavior I/O question: decided (a)

**K2-Q1. May a handler reach `ctx.services` inside a step? Decided (a)** (maintainer, 2026-11-25). K2 leaves `ctx.services` unchanged and documents the rule:
- time comes from `ctx.tickId`;
- randomness comes from `ctx.random`;
- outside data comes through resolvers;
- in a handler, only constant (config) services or write-only (sink) services, neither of which blocks.

**Follow-ups:**
- **#855** (before-release): the tightening, option (b) below. A handler's services are limited to `ReadOnlyLandService` plus a sink marker, as `validate`'s are.
- **#854** (before-release): a determinism test helper for land authors: record, replay and compare per-tick hashes in a unit test. It lets a land author check the rule above on their own land.

**K2's doc tasks** (in K2-2, which moves handlers into steps; both languages):
- `LandContext.services`' `///` doc states the rule;
- `docs/core/land-dsl.md` and `docs/core/land-dsl.zh-TW.md`, in the LandContext section (where `services` is listed), state the rule with the three kinds and point at resolvers for outside data.

The analysis that led to the decision:

The core's `Behavior` contract (Machine.swift's doc) says a step is synchronous and deterministic and touches nothing outside the model; anything that waits or does I/O goes out as an effect. After K2, handlers run inside steps, and `ctx.services` lets a handler reach any registered service. That is the one place where today's API and the core's contract disagree (survey §2).

What the repository's handlers do with it today falls into three kinds:
- **Constant reads (config).** HeroDefenseLand, and its `CombatSystem` and `MonsterSystem` called from handlers and the tick, read `GameConfigProviderService`. Damage, the spawn ramp and the like go into state. The config doesn't change during the land's life, so the reads are deterministic and replay repeats them. They fit the Behavior side of the contract: fixed configuration.
- **Write-only sinks.** `InputProbe.noteApplied()` (VisibilityTestLand) is a counter for the benchmark. `HeroDefenseStats` is a JSONL stats sink that GameServer registers for live lands only. Nothing they return reaches state.
- **External I/O.** `SimulatedExternalService` (ResolverTestLand) is called only from resolvers, which run outside steps, as effects.

A service whose answer changes between runs (a clock, a remote call) and that a handler reads into state breaks replay today already: the record doesn't hold the answer. So the question is what K2 promises, not what it fixes.

**Prior art in this repository.** #586 already has a marker for the first kind: `ReadOnlyLandService`, with `ReadOnlyLandServices` as the only services `validate` can fetch (ValidateContext.swift). Its doc states the contract: it only reads, and the same inputs give the same answer.

| Option | What it means | For a land author | Cost |
|---|---|---|---|
| **(a) A documented exception (recommended for K2)** | Handlers keep `ctx.services`. The docs name the three kinds: a handler may read constant services and write to sinks, and external I/O goes through a resolver. The same status as an `@Internal` field holding a class | Nothing changes | Docs only; K2 keeps "no public change" (parent §8) |
| (b) The kinds by type, reusing #586's marker | A handler's context fetches only services marked for steps: `ReadOnlyLandService` for constant reads (already the `validate` rule), plus a new sink marker for write-only services. Other services are reachable only from resolvers | Config services already conforming to `ReadOnlyLandService` need nothing more; a sink adopts the sink marker; a land that reads anything else in a handler moves the read to a resolver | A public break. Like `ReadOnlyLandService`, the markers state a trust contract the compiler can't check |
| (c) No services in handlers | `ctx.services` is removed from `LandContext` in handlers. Constant config moves into the land's configuration (Behavior). Observation goes out as outputs: a handler stages a note, and `flush` delivers it to a sink registered on the keeper, after the step | Config becomes land configuration; sinks become output consumers; reads move to resolvers | A public break; the purest fit with the core (the Elm and Redux shape: no I/O in `update` or a reducer; effects outside). The flush adds a hop per note |

**Recommendation (taken):** (a) in K2, so the cut-over stays free of public changes. For the end state, (b) now looks the better candidate than (c) (Review agrees, pre-read of draft 1): it extends a marker the repository already uses for `validate`, and it keeps the config reads that hero-defense depends on. The before-release issue is #855, filed for (b). Prior art beyond the repository: for (a), Erlang's `gen_server` lets `handle_call` do side effects and relies on convention; for (c), Elm's `update` returns `Cmd`, and Redux keeps side effects in middleware.

## 6. Slicing K2 into PRs (agreed by Review's pre-read, with four conditions)

Parent §5 has K2 as one slice. It is the largest one, so K2 is four PRs, each building green:

| PR | Content | Behavior change | Host A/B |
|---|---|---|---|
| **K2-1, the types** | `KeeperInput`, `KeeperQuery`, `KeeperEffect` and the rest; `extension KeeperModel: TurnMachine`. `handle` calls the very K1b-5 bodies and segments the keeper calls, not copies, so the two can't drift (condition 1). The callback audit (§4.5, condition 3). The lint fixture for the facade. Not wired: the keeper doesn't use it yet | none | none (not wired) |
| **K2-E, the step scope** | `StepScope` (the RNG service and the emitter scope), bound in `withHandlerStep`; the counter and `syncRequestsByTick` stay in the collector (they move into the model in K1b-5's move commit, ending K1b-4's D1). On today's keeper (condition 2) | yes, the one in K2: an emit from a context kept past its step is dropped and counted (parent §8) | small: it touches the emit path |
| **K2-2, the cut-over** | the facade and `KeeperOwner`; every entry forwards to the core; the binding token, the services table, the package admission path, the drivers. A pure cut-over. The K2-Q1 docs (§5) | none | full, plus §8's three cells |
| **K2-3, the leftovers** | the code paths K2-2 made unreachable, each proven unreachable on live keepers **and in the replay owner**: until #612, replay calls the same bodies without a core (§7.2), so a path dead on live keepers can still be live in replay (condition 4). K9 still owns the deletions that need K3–K7 | none | none, unless it touches a hot path |

**K2-1's tests are a unit-level differential.** Each §4.3 flow row is driven twice on the same inputs: through a test `TurnCore` running the machine, and through the keeper's direct path. The resulting model and outputs are compared. Draft 6 adds one ordered trace per run, compared entry by entry: the staged actions, the recorder hand-offs, the port calls, and the frames enqueued, with their contents.
- The trace runs on an eventful path (a tick that emits events and syncs) and on a refusal path (a port callback refused mid-step).
- It reruns at the cut-over (K2-2), after K2-E has moved the emitter.

## 7. Risks and ordering constraints

### 7.1 #852 and the adapter's membership queue

#852 (a duplicate login can take a land past `maxPlayers`) can't be reached by a client today, only because the transport adapter runs every join, kick included, inside its membership queue (`enqueueMembership`). A server that calls the keeper's public `join` can reach it.
- **K2 keeps the adapter's membership queue.** K2 doesn't change the adapter's intake; the adapter's B-slices (#546) are out of #700's scope.
- **The constraint:** retiring the adapter's membership queue (in an adapter B-slice, or because K2's join steps make it look redundant) opens #852 to clients, unless #852's fix (a), the returning player's held place, has landed, or K6 has made the join one step. Whoever retires the queue checks this first.
- K2 itself doesn't widen the window: J3 still runs after the kick's result input, as today. K2's join tests include #852's interleaving under whatever #852's decision is at K2's base.

### 7.2 Others

- **Exclusivity.** Inside a step, `self` is the model and the only access to it (survey §1). The scoped emitter exists so the closures write separate storage. K2 changes how a re-entry is stopped (new in draft 5, narrowed in draft 6):
  - Today (K1b-4) the model is the actor's stored `model`. Swift's dynamic exclusivity check catches a handler that reads it during `withHandlerStep`. P4 and `KeeperReentryTrapTests` are evidence for that stored-property path, not for K2's. The test runs only with `KEEPER_REENTRY_TRAP=1`, and only in debug builds (`isDebugBuild`).
  - In K2 the model is the core's `machine`, which release builds mark `@exclusivity(unchecked)` (#621), so Swift's check no longer catches the overlap in release. **What the core stops** (TurnCore.swift:90–100): a `read` or a `query` inside a step, and a step inside a step or inside a read. With (a), the guarded entries refuse before the core is reached (§4.2).
  - **What the core doesn't stop:** adopter code it runs during its own accesses: `M.Key`'s `==` and `hash(into:)`, and the deinits of inputs and keys it drops. The callback audit (§4.5) covers `KeeperKey` and the `KeeperInput` payloads. The keeper suites also run once in a release build with `-Xswiftc -DTURNS_EXCLUSIVITY_CHECKED` (cloud), which turns Swift's check back on for the core's state.
  - A handler that reaches the model some other way, which the facade doesn't offer, would not be caught.

  K2-2 points `KeeperReentryTrapTests` at K2's stops. The refused entry is observed by a count, with no crash, so it runs in the normal suite. The core's stop runs one case per process in the cloud. Both need the `isDebugBuild` gate removed, so that they run in debug and in release. The contract docs that K1b-4 wrote (runtime.md, both languages; `LandContext`'s doc; `clearDirty()`'s doc) name K2's stops instead of Swift's check.
- **Assignments into the model.** K1b-4 found that an optional-chain assignment into the model begins its access before it evaluates the call on its right side (`Notes/solutions/2026-11-26-assignment-into-a-struct-field-begins-its-access-before-the-call-on-the-right.md`). In a step, `self` is the model. So the optional-chain form, with a mutating call on the right that reaches `self`, is a compile-time overlap, not a run-time one (P6). The plain subscript and plain field forms compile. K2-1's `handle` is written with locals first, as K1b-4's three sites are.
- **The per-message cost.** A query intake's cost is not established (parent §3.8). K2-2's A/B measures it on tick actions with and without resolvers and on tickless client events. Over budget means a core fix (G5 #761), not a keeper shortcut.
- **G3 (#760, step-path specialization)** is checked before K2-2's A/B is read. A generic machine in another module that isn't specialized could show up as a regression that isn't the keeper's.
- **A missed callback.** A port call that reaches back into the keeper during a step is refused (a matrix row) or stops the process (a row that keeps the core's stop). The audit (§4.5) and the debug check (§4.2) find it before the cut-over, and the full E2E in three encodings exercises it.
- **Replay drift.** The replay owner calls the same bodies without a core (parent §3.10). A step-only check added in K2 (a token or a ticket) must have a replay path, or replay skips it. K2-2's harness pass and the reevaluation E2E (0 mismatch) catch a divergence.

## 8. Tests and measurement

- **Tests:** parent §6.2's K2 list, unchanged: each §3.3 contract, the order test, the barriers, the result slot, cancellation with its mutant, the entry end and the seal. Plus:
  - the census (K1b-4's `KeeperCensusTests`, which keys rows by storage path and checks each row's home against its container) extended: a `live.` group for `LiveLandTurns`, which holds only the core, the mailbox, the config, the facade, the binding token and the services table. The actor's rows leave as K2-2 moves them. #865's sentinel rows (`.outside(.reentrySentinel)`, `.outside(.turnSide)`) follow K2-Q3's answer;
  - the replay owner holds no `TurnCore` or `TurnActor` (parent §3.10's `Mirror` test);
  - the scoped emitter: an emit from a context kept past its step is dropped and counted.
- **Every slice's runs** (parent §5): both test legs, the two example packages, E2E in three encodings and the game E2E with reevaluation, release, must-not-compile, a mutant per new rule. CI and the cloud run the parts the Mac doesn't.
- **The differential harness:** no difference allowed.
- **Host A/B** (the maintainer's rule of 2026-11-26): an A/B never gates a merge. It runs after the merge, on the merged SHA, and a regression becomes an issue. The tiers in §6 say which PRs get one. K2-2 gets the full A/B: tick actions without resolvers, tick actions with resolvers, tickless client events. G3 is checked before it is read.

## 9. Questions

| # | Question | For | Blocks |
|---|---|---|---|
| K2-Q1 | `ctx.services` in steps (§5) | **decided (a)** (maintainer, 2026-11-25); (b) is #855 | — (K2-2 carries the docs) |
| K2-Q2 | Four PRs instead of one (§6) | Review: agreed in the pre-read, with four conditions, which §6 takes; confirmed in the review of this plan | K2-1 |
| K2-Q3 | A re-entry into a keeper entry during a step: keep #865's refuse-and-end-the-land (a), or take the core's stops (b)? (§4.2: (a)'s mechanism, matrix, P5) | Review, then the maintainer if (b), since (b) is a behavior change | K2-1's facade check and the core's `isStepping` |

## 10. Draft 1 → draft 2

| Change | Source | Where |
|---|---|---|
| Four PRs: K2-1 calls the same bodies, with a unit differential; K2-E (the step scope) between K2-1 and K2-2; the callback audit in K2-1; K2-3 proves unreachability in replay too; A/B tiers per PR | Review's pre-read, K2-Q2's four conditions | §4.4, §4.5, §6, §9 |
| K1b-5's request enums: I/O cases become effects, barriers become entry policies, reply waits become replies | K1b-5 rev 2 §4 | §2, §4.1, §4.3 |
| `KeeperTurnSide` as methods, each with its K2 route; `closeOutputs` and `syncNowInTurn` direct on the binding token, the rest staged | agreed with K1b-5's author for its rev 2.1 | §4.5 |
| `KeeperReply` carries any error; tickless results ride `.awaitRecordTaken` and its result input, so the failure table holds only unwaited failures | Review's pre-read | §4.1, §4.3 |
| `EntryID` is the entry generation, `BindingID` the sync binding's ticket | Review's pre-read | §4.1, §4.5 |
| The debug check's mutants: cloud, one case per process, plus a count | Review's pre-read | §4.2 |
| Review agrees (b) beats (c) for K2-Q1's end state | Review's pre-read | §5 |

## 11. Draft 2 → draft 3

| Change | Where |
|---|---|
| K2-Q1 decided (a) by the maintainer; the rule; #855 (the tightening, (b)) and #854 (the determinism test helper) as follow-ups; the docs passage as K2-2's doc task | §5, §6, §9 |

## 12. Probes

Each point below rests on Swift semantics, so it is checked by a probe, not argued. The probe files are next to this plan, with their commands and expected output in their headers, so a review can rerun them at the pinned toolchain: `2026-11-25-k2-probe-p1-p3.swift` (typecheck against the built modules) and `2026-11-25-k2-probe-p2-p4.swift` (self-contained; run on Linux, since its trap mode crashes on purpose).

| # | Point (section) | Probe | Result |
|---|---|---|---|
| P1 | `extension KeeperModel: TurnMachine` satisfies `TurnActor`'s `M: TurnMachine & PlainData` inside the generic keeper, with `Behavior = KeeperBehavior<State>` (§3) | a generic `ProbeModel<State: StateNodeProtocol>` whose `PlainData` conformance is conditional on `State: PlainData` (the shape `@PlainData` generates for a generic struct), a generic behavior, `actor ProbeLive<State>: TurnActor`, built through `TurnCore(machine:behavior:queueLimit:maxReleasesPerBatch:clock:)`. `swiftc -typecheck -swift-version 6` against the built `SwiftStateTurns` and `SwiftStateTree` modules (Apple Swift 6.4.2; `SwiftStateTurns` identical to main's) | positive: exit 0. Negative (the condition changed to `State: Hashable`): exit 1, `error: type 'ProbeLive<State>' does not conform to protocol 'TurnActor'`. So the condition `StateNodeProtocol` already implies (P4-1) is what makes it hold |
| P2 | the facade adopts `LiveLandTurns`' executor and forwards with `live.assumeIsolated { … }` (§3) | compile: the same file as P1 (`nonisolated var unownedExecutor: UnownedSerialExecutor { live.unownedExecutor }`, `func forward() -> Int { live.assumeIsolated { $0.liveOnly() } }`). Run: a self-contained file, on Linux | compile: exit 0. Run (Linux, Swift 6.4.3), control mode, `-Onone` and `-O`: exit 0, stdout `P2 forward: 3` then `step done: state=1`. So `assumeIsolated` from the facade's own isolated method passes on the shared executor |
| P3 | `LiveLandTurns` holds the facade `nonisolated(unsafe) weak` (§3) | `nonisolated(unsafe) weak var facade: AnyObject?` on the actor, in P1's file | exit 0 |
| P4 | a handler (or a service it calls) that reaches the facade or `core.read` from inside a step traps, in debug and release (§7.2). Draft 6: evidence for K1b-4's stored-property path (a step that holds `&model` on the actor), not for K2, where the model is the core's unchecked `machine` (§7.2) | a self-contained file: a step holds `&model` for its whole body (`withHandlerStep`'s shape); the handler reads `model` through the facade and `assumeIsolated`. Built `-Onone` and `-O`, run in a control mode (no re-entry) and a trap mode, on Linux (a trap on the Mac opens a crash dialog) | Swift 6.4.3, Linux. Control, both builds: exit 0, `step done: state=1`. Trap, both builds: exit 134, stderr `Simultaneous accesses to 0x…, but modification requires exclusive access`, `Previous access (a modification) started at…`, `Current access (a read) started at:`, and no `step done` line. So the check holds in `-O` too: a synchronous call back into the keeper during a step is a run-time trap in release, not only in debug. In the trap runs stdout was lost at the abort (file buffering), so P2's line doesn't show there; the control runs carry it |
| P5 (draft 6) | K2-Q3 (a): a re-entry through the facade during a core step is refused, with no crash, by a predicate the core owns. The running step sees the refusal after its port call returns, and applies the failure to its own model (§4.2) | `2026-11-26-k2-probe-p5.swift`, self-contained. `ProbeCore` copies the core's borrow rule and adds the proposed `isStepping`. The facade adopts the live actor's executor and installs the live actor's weak backlink in its init. The port calls back through `facade.assumeIsolated { $0.submitSyncStream() }` during a step. It runs three cases: a control (the entry outside a step), a step entered through the facade, and a step the live actor starts itself (a timer). Mac, Apple Swift 6.4.2, `-Onone` and `-O` | both builds exit 0, with stdout `control: accepted=1 violations=0 failed=false`, `facade step: refused=1 violations=1 failed=true gateCloses=1 borrows=0`, `core-driven step: refused=1 violations=2 failed=true gateCloses=2 borrows=0`, `done`. So the refusal needs no facade-side counter: the core-driven step is refused the same way. Limit: the borrow rule is a copy, so K2-1's tests repeat this against the real `TurnCore` with its `isStepping` |
| P6 (draft 6; Review's probe) | an assignment into the model whose right side mutates the model, inside a step, where `self` is the model (§7.2) | Review's `neg.swift` / `pos.swift`: a struct with `mutating func held`, built with Apple Swift 6.4.2 | `slots[k]?.result = held(o)` is refused: `error: overlapping accesses to 'self.slots' … [#ExclusivityViolation]`. The plain subscript set, the plain field assignment and locals first all pass. The diagnostic comes from the SIL pass: `swiftc -typecheck` accepts the file, and `-emit-sil` or a build refuses it. So in a step the optional-chain shape is a build error, not a run-time trap |


What the probes don't cover:
- the per-step scoped emitter (§4.4): a lock and a flag, ordinary code that K2-E's own tests pin;
- G3's specialization (§7): a measurement, not a probe.

## 13. Draft 3 → draft 4

| Change | Where |
|---|---|
| The probes for the Swift-semantics points (the maintainer's rule of 2026-11-25: every plan revision has a probe section); the probe files committed next to the plan (Review's early look) | §12 |

## 14. Draft 4 → draft 5

| Change | Source | Where |
|---|---|---|
| §2 retaken on what landed: K1b-4's split, its counts, `state` last, the actor-side fields, `withHandlerStep`'s `inout` model, the census. #865's `withTurn`, `TurnOutputs`, `KeeperTurnSide`, `callOut` and the sentinel | #877 at e18e70c0, #865 at 65cced07 | §2, Inputs |
| K2-Q3: the core's borrow stops and #865's sentinel act differently on a re-entry; (a) is recommended | TurnCore.swift:90–125; #865 | §4.2, §9 |
| How K2-1 maps #865's side, outputs and `callOut` into a step, with the submission trace in the differential | #865 | §4.5 |
| The services table's landed shape and its 10 write sites | #877 | §4.5 |
| Under K2, the re-entry is caught by the core's borrow rule, not by Swift's exclusivity check (`machine` is unchecked in release, #621). The trap test and the contract docs follow | TurnCore.swift:90–125; #877's contract | §7.2 |
| Assignments into the model: write locals first | K1b-4's solutions entry | §7.2 |
| The census extended by storage path; the A/B rule of 2026-11-26 | #877; the maintainer | §8 |

**Probes:** none new in draft 5 (draft 6 adds P5 and quotes P6, §12). Draft 5's reasons:
- P1's shape (a generic model whose `PlainData` is conditional) is what landed. `KeeperCensusTests`' `requirePlain(KeeperModel<CensusState>.self)` compiles in #877.
- The core's release stop is `fatalError` in `read` (TurnCore.swift:477), code the turn core's own tests cover, not a compiler rule.
- K2-Q3 is a choice, not a semantic point.

## 15. Draft 5 → draft 6 (Review's NOT GO on draft 5: 3 must-fix, 3 should, 3 nits)

| Finding | Change | Where |
|---|---|---|
| MF1: (a) had no mechanism | The predicate is a package `isStepping` on the core, not a facade counter. The refusing entry counts the trip, notes it in the mailbox and closes the gate under #865's guard. `callOut` in the step sees the trip and ends the land through the step's own model. Factories run in the step. The backstop is the step's last action, before the core's flush. Probe P5 | §4.2, §12 |
| MF2: the entry matrix | For each entry: how production reaches it, today's behavior, and K2's (refused, a step-local answer, the core's stop, or deferred). The debug check's name comes from the facade entry. The trap test's debug gate is removed in K2-2 | §4.2, §7.2 |
| MF3: output order | Events keep the in-phase batch on eventful paths; `turn.emit` carries no events. The differential compares one ordered trace on an eventful path and a refusal path, and reruns at the cut-over | §4.4, §6 |
| should 1 | §7.2 is narrowed to what the core stops. The audit adds `KeeperKey` and the `KeeperInput` payloads. The keeper suites run once with `TURNS_EXCLUSIVITY_CHECKED` in release | §4.5, §7.2 |
| should 2 | Review's exclusivity probe is quoted as P6 | §12 |
| should 3 | The admission path's two bypassed callbacks are named, and the `.legacyCycle` and disconnect submissions are shown to run outside a step | §4.5 |
| Nits | The fixed-offset claim cites the cloud's count. P4 is labelled as K1b-4's evidence. Anchors corrected: TurnActor.swift:904 (the flush call; :897 is `drainProducts`), TA:113 (`unownedExecutor`) | §2, §3, §4.4, §4.5, §12 |

TA anchors in draft 6 are at e18e70c0 (main's `TransportAdapter.swift` is the same file), found by grep, not by the LSP.

## 16. K2-1 PR checklist (Review's shoulds and nits on draft 6)

Each line is checked in K2-1's PR body, with its anchor at the PR's base. The anchors below are Review's, at e18e70c0 / 19fe61e5.

1. **P5's claim.** Case 2 reuses `live`, which case 1 left with `failed = true`, so `failed=true` in case 2 proves nothing new. K2-1 reruns P5 with a fresh model per case, or narrows the claim to the counts (`violations`, `gateCloses`).
2. **`callOut`'s order.** K2-1 keeps #865's flush → check → call → check (LK:5544–5554). The sync-only turn checks once, after the whole draft batch and before the phase result applies (LK:5889–5935). `KeeperTurnSkeletonTests` pins the trace `sync-output, sync-output, terminal, endTurn`. The backstop is only for late trips. The same-gate skip (`reentryClosedGate`) carries over.
3. **`markFailedFirst`.** Today `drainFlag.setFailed` publishes `failure`, `isDraining` and `destructionCause` before `failLand` closes the gate (LK:621–630, :6342–6376). K2-1 either sets the atomic directly in the step, as it does the close, or pins what the port sees at the gate close.
4. **The matrix, completed** (§4.2):
   - add `setTransport`, `debugResume`, `submitLandFailure`, `currentStateLocated`, `entrySession` and `syncReadPosition`;
   - split the "send entries" row: several are `sendAndWait` or queries, not sends;
   - name where `isStepping` refuses more than `bodyDepth` does today: `settleTurn`'s port call runs outside `withTurn` (LK:6082–6100; K1b-5a step 2 moves it inside), and `syncTurnNow`'s port witness runs before its guarded body;
   - add the freeze settle (TA:6264) and the resume's `syncTurnNow` (TA:6415).
5. **The core's flush.** A query made from the flush is answered in place, and a send is queued (TurnActor.swift:88–103, :810–835). K2-1 lists what a staged action may call. The differential gets one case that submits and then queries from one flush.
6. **`recordSyncStreamClear`'s other callers.** It is also called from standalone registration and from the fallback admission (TA:1601, :2283–2291). K2-1 keeps the helper that runs outside a step, and keeps both removals from the tracking set.
7. **Nit:** the `recordsSyncStream` row now says it reads no model field (§4.2). Done in draft 7.
8. **Nit:** the core's stop messages are cited, at TurnCore.swift:477, :644 and :580–581 (§4.2). Done in draft 7.
9. **Nit:** §7.2's overlap wording is limited to the optional-chain form, and the citation of K1b-5's D2 names its branch and commit. Done in draft 7.

## 17. Draft 6 → draft 7

| Finding | Change | Where |
|---|---|---|
| MF: a tokenless step can't reach the sentinel | The sentinel is a `let` reference in `KeeperBehavior`, reached through `turn.behavior` / `MailTurn.behavior` by every step kind. It is a stated exception to Machine.swift's advice, listed for #773. K2-1 pins a tokenless core-driven step whose backstop ends the land in that step | §4.2 |
| 6 shoulds, 3 nits | Tracked as the K2-1 PR checklist; the three nits are fixed here | §16, §4.2, §7.2 |

**Probes:** none new. The MF is about routing: which step kinds receive `turn.behavior` is in the core's signatures (Machine.swift:47–56), not a Swift-semantics question. K2-1's tokenless-step test is the evidence.

# K2: the keeper's cut-over onto the turn core (#700)

**Status:** draft 4, prep only. Draft 4 adds the probes (§12) for the points that rest on Swift semantics: the machine's conformance, the shared executor, the facade's weak reference and the exclusivity trap. Draft 3 records K2-Q1, decided (a) by the maintainer (2026-11-25), with #855 as its follow-up and #854 (§5, §9). **Not for Review until K1b lands:** K2 starts from K1b-5's end state, and its line numbers, segment names and type names are re-taken on K2's base. Draft 2 takes Review's pre-read of draft 1 (not a verdict): K2-Q2's split, agreed with four conditions, and its §4 notes. It also takes K1b-5 rev 2's shape (each segment returns its await's request) and the `KeeperTurnSide` interface agreed with K1b-5's author for rev 2.1 (§4.5). §10 lists the changes. Draft 1 was read at main 7baba4c4, without the LSP.

**Inputs:**
- the parent plan `2026-11-22-keeper-on-turncore.md` rev 5.8: §3.1–§3.10, §5's K2 row, §6.2's K2 tests, §7 and §8;
- the K2 prep survey `2026-11-25-k2-prep-survey.md`;
- the K1b slice plans: K1b-1 (plain forms), K1b-2 (failure IDs and the side tables), K1b-3 (the land's generator, PR #853), K1b-4 rev 2.1 (`KeeperModel`, `KeeperBehavior`, the `playerServices` table; Review GO), K1b-5 rev 2 (turn bodies, and segments that return their await's request);
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
| K1b-4 | `KeeperModel<State>` (`@PlainData`): the machine's state. `KeeperBehavior<State>`: the machine's `Behavior` (#768). One `inout` access of the model per step |
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
- **The executor:** the facade adopts `LiveLandTurns`' executor, and the adapter adopts the facade's (TA:105), so all three share one serial executor. The facade forwards with `live.assumeIsolated { … }`.
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
- **Queries can't wait.** A query is used only where today's caller gets its answer at intake (the tick ACK, the two-phase action's `.pending`, the server input's `.accepted`).
- **Barriers, not holds** (parent §3.3.1). The initialization and freeze barriers read the model through `core.read` and wait on `sendAndWait(.awaitInitialized)` / `.awaitResume`. No intake is parked by a hold, so a query can't overtake a parked `sendAndWait`.
- **The debug check:** a synchronous step entry (`query`, and the keeper's synchronous entries that step) called from inside a keeper step traps with the entry's name. A mutant aimed at it is killed by a crash, so it runs in the cloud, one test case per process (K1b-2's lesson); the check also bumps a count that a normal test reads.

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
- **The sequence counter** (`nextSequence`, `checksOverflow`, `sequenceExhausted`) and `syncRequestsByTick` move from `OutputCollector` into the model. This ends K1b-4's D1.
- **The scoped emitter:** each handler call gets a per-step scope (a lock-protected open flag and the staged list). `LandContext`'s three output closures capture the scope, not the model. The step moves the staged events into `turn.emit` after the handler returns, and closes the scope. A call after that is dropped and counted, asserted in debug. That is a visible behavior change, stated in K2's PR (parent §8).
- **Record drafts** are outputs. `flush` hands them to the recorder's serial sink in step order (TurnActor.swift:897's flush after each step).
- **The in-turn sync phase** stays inside the step and calls the port through the binding token (parent §3.7).

### 4.5 Ports, tokens and the services table (parent §3.1, §3.7)

- **The binding token** (the port plus its `BindingID`) is attached by the entries that need the port. The step checks the `BindingID` against the model's, then calls the port's synchronous in-turn methods.
- **`KeeperTurnSide` in a step.** A core step gets only the model (`self`), `turn` (the behavior, which holds no mutable reference, plus `emit` and `run`) and the input. So K2 can't hand a body the actor's `&turnSide`. K1b-5 rev 2.1 makes `KeeperTurnSide` an interface of methods: reads are methods, and every write is staged in `TurnOutputs`. K2-1's `handle` builds a step-local side from the input and a staging buffer, and calls the same bodies. Each method's route:

| `KeeperTurnSide` method | K1b-5 (on the actor) | K2 (in a step) |
|---|---|---|
| `services(for:generation:)`; inserts and removals staged | the actor's `playerServices` | reads from the overrides on the input; writes are outputs that `flush` applies to `LiveLandTurns`' table |
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
- **The callback audit, in K2-1 or before it** (Review's condition 3), not inside K2-2: grep the adapter for every `keeper.assumeIsolated` and list each with the path that reaches it. One that a step can reach is a stop, and it moves the plan before the big PR is written.
- **The per-player services table** lives on `LiveLandTurns`, keyed by `(PlayerID, EntryID)`, the same key as K1b-4's `playerServices` (`EntryID` is the entry generation). `flush` writes it from the join step's output and removes it on the leave step's output. The queued OnLeave handler's lookup at apply time (K1b-4 §3.3) reads the current entry's overrides, which the tick driver attaches to `.tickDue`'s input.

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
| **K2-E, the step scope** | `StepScope` (the RNG service and the emitter scope), bound in `withHandlerStep`; the sequence counter into the model (ends K1b-4's D1). On today's keeper (condition 2) | yes, the one in K2: an emit from a context kept past its step is dropped and counted (parent §8) | small: it touches the emit path |
| **K2-2, the cut-over** | the facade and `KeeperOwner`; every entry forwards to the core; the binding token, the services table, the package admission path, the drivers. A pure cut-over. The K2-Q1 docs (§5) | none | full, plus §8's three cells |
| **K2-3, the leftovers** | the code paths K2-2 made unreachable, each proven unreachable on live keepers **and in the replay owner**: until #612, replay calls the same bodies without a core (§7.2), so a path dead on live keepers can still be live in replay (condition 4). K9 still owns the deletions that need K3–K7 | none | none, unless it touches a hot path |

**K2-1's tests are a unit-level differential.** Each §4.3 flow row is driven twice on the same inputs: through a test `TurnCore` running the machine, and through the keeper's direct path. The resulting model and outputs are compared.

## 7. Risks and ordering constraints

### 7.1 #852 and the adapter's membership queue

#852 (a duplicate login can take a land past `maxPlayers`) can't be reached by a client today, only because the transport adapter runs every join, kick included, inside its membership queue (`enqueueMembership`). A server that calls the keeper's public `join` can reach it.
- **K2 keeps the adapter's membership queue.** K2 doesn't change the adapter's intake; the adapter's B-slices (#546) are out of #700's scope.
- **The constraint:** retiring the adapter's membership queue (in an adapter B-slice, or because K2's join steps make it look redundant) opens #852 to clients, unless #852's fix (a), the returning player's held place, has landed, or K6 has made the join one step. Whoever retires the queue checks this first.
- K2 itself doesn't widen the window: J3 still runs after the kick's result input, as today. K2's join tests include #852's interleaving under whatever #852's decision is at K2's base.

### 7.2 Others

- **Exclusivity.** Inside a step, `self` is the model and the only access to it (survey §1). A handler's closure that reaches the facade or `core.read` from inside the step would trap. The scoped emitter exists so the closures write separate storage.
- **The per-message cost.** A query intake's cost is not established (parent §3.8). K2-2's A/B measures it on tick actions with and without resolvers and on tickless client events. Over budget means a core fix (G5 #761), not a keeper shortcut.
- **G3 (#760, step-path specialization)** is checked before K2-2's A/B is read. A generic machine in another module that isn't specialized could show up as a regression that isn't the keeper's.
- **A missed callback.** A port call that reaches back into the keeper during a step traps at run time. The audit (§4.5) and the debug check (§4.2) find it before the cut-over, and the full E2E in three encodings exercises it.
- **Replay drift.** The replay owner calls the same bodies without a core (parent §3.10). A step-only check added in K2 (a token or a ticket) must have a replay path, or replay skips it. K2-2's harness pass and the reevaluation E2E (0 mismatch) catch a divergence.

## 8. Tests and measurement

- **Tests:** parent §6.2's K2 list, unchanged: each §3.3 contract, the order test, the barriers, the result slot, cancellation with its mutant, the entry end and the seal. Plus:
  - the census (K1b-4) extended: `LiveLandTurns` holds only the core, the mailbox, the config, the facade, the binding token and the services table;
  - the replay owner holds no `TurnCore` or `TurnActor` (parent §3.10's `Mirror` test);
  - the scoped emitter: an emit from a context kept past its step is dropped and counted.
- **Every slice's runs** (parent §5): both test legs, the two example packages, E2E in three encodings and the game E2E with reevaluation, release, must-not-compile, a mutant per new rule. CI and the cloud run the parts the Mac doesn't.
- **The differential harness:** no difference allowed.
- **Host A/B: full**, plus three cells: tick actions without resolvers, tick actions with resolvers, tickless client events. G3 is checked before it is read.

## 9. Questions

| # | Question | For | Blocks |
|---|---|---|---|
| K2-Q1 | `ctx.services` in steps (§5) | **decided (a)** (maintainer, 2026-11-25); (b) is #855 | — (K2-2 carries the docs) |
| K2-Q2 | Four PRs instead of one (§6) | Review: agreed in the pre-read, with four conditions, which §6 takes; confirmed in the review of this plan | K2-1 |

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

Each point below rests on Swift semantics, so it is checked by a probe, not argued. The files are kept with the plan's working notes; the code is quoted where it decides the point.

| # | Point (section) | Probe | Result |
|---|---|---|---|
| P1 | `extension KeeperModel: TurnMachine` satisfies `TurnActor`'s `M: TurnMachine & PlainData` inside the generic keeper, with `Behavior = KeeperBehavior<State>` (§3) | a generic `ProbeModel<State: StateNodeProtocol>` whose `PlainData` conformance is conditional on `State: PlainData` (the shape `@PlainData` generates for a generic struct), a generic behavior, `actor ProbeLive<State>: TurnActor`, built through `TurnCore(machine:behavior:queueLimit:maxReleasesPerBatch:clock:)`. `swiftc -typecheck -swift-version 6` against the built `SwiftStateTurns` and `SwiftStateTree` modules (Apple Swift 6.4.2; `SwiftStateTurns` identical to main's) | positive: exit 0. Negative (the condition changed to `State: Hashable`): exit 1, `error: type 'ProbeLive<State>' does not conform to protocol 'TurnActor'`. So the condition `StateNodeProtocol` already implies (P4-1) is what makes it hold |
| P2 | the facade adopts `LiveLandTurns`' executor and forwards with `live.assumeIsolated { … }` (§3) | compile: the same file as P1 (`nonisolated var unownedExecutor: UnownedSerialExecutor { live.unownedExecutor }`, `func forward() -> Int { live.assumeIsolated { $0.liveOnly() } }`). Run: a self-contained file, on Linux | compile: exit 0. Run: PENDING (cloud) |
| P3 | `LiveLandTurns` holds the facade `nonisolated(unsafe) weak` (§3) | `nonisolated(unsafe) weak var facade: AnyObject?` on the actor, in P1's file | exit 0 |
| P4 | a handler (or a service it calls) that reaches the facade or `core.read` from inside a step traps, in debug and release (§7.2) | a self-contained file: a step holds `&model` for its whole body (`withHandlerStep`'s shape); the handler reads `model` through the facade and `assumeIsolated`. Built `-Onone` and `-O`, run in a control mode (no re-entry) and a trap mode, on Linux (a trap on the Mac opens a crash dialog) | PENDING (cloud) |

What the probes don't cover:
- the per-step scoped emitter (§4.4): a lock and a flag, ordinary code that K2-E's own tests pin;
- G3's specialization (§7): a measurement, not a probe.

## 13. Draft 3 → draft 4

| Change | Where |
|---|---|
| The probes for the Swift-semantics points (the maintainer's rule of 2026-11-25: every plan revision has a probe section) | §12 |

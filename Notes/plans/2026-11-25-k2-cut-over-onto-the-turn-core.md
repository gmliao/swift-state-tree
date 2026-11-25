# K2: the keeper's cut-over onto the turn core (#700)

**Status:** draft 1, prep only. **Not for Review until K1b lands:** K2 starts from K1b-5's end state, and its line numbers, segment names and type names are re-taken on K2's base. This draft puts K2's shape on paper early, as the main line's next large step. It was read at main 7baba4c4, without the LSP.

**Inputs:**
- the parent plan `2026-11-22-keeper-on-turncore.md` rev 5.8: §3.1–§3.10, §5's K2 row, §6.2's K2 tests, §7 and §8;
- the K2 prep survey `2026-11-25-k2-prep-survey.md`;
- the K1b slice plans: K1b-1 (plain forms), K1b-3 (the land's generator, PR #853), K1b-4 rev 1.2 (`KeeperModel`, `KeeperBehavior`), K1b-5 draft 1 (turn bodies and named segments);
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
| K1b-5 | The turn bodies as `mutating` methods on `KeeperModel` that take the behavior and return `TurnOutputs`. Every async flow as named synchronous segments (J1–J4, L1–L3, the action, intake and driver flows), with what crosses each await |
| K1b-3 | `landRandom` in the model; `withHandlerStep` as a model method |
| K1b-1 | The queued items' plain forms. K1b-Q5 (d): `PendingActionItem` and `PendingClientEventItem`, and their inits, are `package` |
| K1a | Raw payload bytes in the record; `InputOutcome` carried to the adapter |

**K2's first check on its base** (no code): every segment K1b-5 named still exists, and every value it marked **not plain** has a carrier in §4.3. A segment or a crossing that K1b-5 missed stops K2 until K1b-5's plan is amended.

## 3. The layout (parent §3.10)

- `LandKeeper<State>` stays the public actor and becomes a facade over `KeeperOwner`:
  - `.live(LiveLandTurns)`, which holds the `TurnCore<KeeperModel<State>>`;
  - `.replay(ReplayLandOwner)`, which holds a `KeeperModel` and no core.
- **This needs the parent plan's Q1, still open.** (c), the facade, is recommended there. K2 can't start before the maintainer decides Q1; the other options change K2's shape (Q1 (b) pulls #612's redesign in).
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
| `Effect` | `KeeperEffect` | one case per await K1b-5 named, carrying what crosses it (§4.3), plus `.awaitRecordTaken(ticket)` |
| `Output` | `KeeperOutput` | record drafts (to the recorder's serial sink), the binding-token and services-table writes (to `LiveLandTurns`' two stored values) |
| `Reply` | `KeeperReply` | each `sendAndWait` entry's answer: `JoinOutcome`, `InputOutcome`, `JoinError`/`LandInputRejection`, `Void` |
| `Key` | `KeeperKey` | `.land`, `.initialization`, `.entry(PlayerID, EntryID)`, `.syncBinding(BindingID)`, `.freeze(FreezeID)` (parent §3.2) |
| `Mail` | `Never` in K2 | K4 makes it `LandReport` |
| `FollowUpSlot` | `Never` in K2 | K3 adds the three slots |

`Input` and `Effect` are `Sendable`, not `PlainData` (Machine.swift:10–12). So a non-plain value can cross an await inside an effect and its result input: the model never stores it.

### 4.2 Entries (parent §3.3, unchanged)

Each row of parent §3.3's table becomes one forwarding method on the facade. The table is the contract, and §6.2's K2 tests pin each row. Three notes for the implementation:
- **Queries can't wait.** A query is used only where today's caller gets its answer at intake (the tick ACK, the two-phase action's `.pending`, the server input's `.accepted`).
- **Barriers, not holds** (parent §3.3.1). The initialization and freeze barriers read the model through `core.read` and wait on `sendAndWait(.awaitInitialized)` / `.awaitResume`. No intake is parked by a hold, so a query can't overtake a parked `sendAndWait`.
- **The debug check:** a synchronous step entry (`query`, and the keeper's synchronous entries that step) called from inside a keeper step traps with the entry's name.

### 4.3 Segments become steps; awaits become `run` (the core of K2)

For each flow, K1b-5's segment before an await ends with `turn.run(.someEffect(captured))`. The effect's `perform` does the await, off the actor, and returns the result input. That input's handler calls the next segment, which re-reads the model and validates, as K1b-5's segment does by hand today.

| Flow | Awaits that become `run` | The result input, and its check |
|---|---|---|
| Join (J1–J4) | CanJoin's resolvers; the kick (`leave`); OnJoin's resolvers | `.joinStepped(stage, ticket, result)`: the entry generation, `isDraining`, and the stale-join refusal, as today |
| Leave (L1–L3) | OnLeave's resolvers | `.leaveStepped(ticket, result)`: `isDraining`, the drop metric |
| Action jobs | the job's resolvers (one `run` per job; K5 makes it a keyed `request`) | `.actionResolved(seq, token, result)`: the job, the entry generation, the sealed token (parent §3.2) |
| Initialization | OnInitialize's resolvers | `.initializeResolved`; K5 adds the key and the deadline |
| Tickless turns | the record submit, then the waiters | `.recordTaken(ticket)`: the waiters' replies come from this step (parent §3.4) |
| The drain | the destroy handlers | `.destroyHandlerResolved`, one at a time; K7 keys them |

**What crosses, and how** (K1b-5 §3's "not plain" marks):
- `LandServices` (the per-player overrides): in the effect, read from `LiveLandTurns`' services table by the entry that names the player (parent §3.1).
- The resolver's `LandContext`: built in the step, carried by the effect. Only its outputs come back, as `[String: HeldResolverOutput]`, which is plain after K1b-1.
- `State` for the resolver: a copy taken in the step (parent §3.1).

**The join's kick is a nested flow.** J2 runs the kick as a `run` of the leave flow's own effect. The leave's steps (L1 runs inside J2's step; its OnLeave await is J2's `run`) then hand back to J3. This is the window #852 is about (§7.1).

### 4.4 Outputs (survey §3; parent §3.1, §3.6)

- **The sequence counter** (`nextSequence`, `checksOverflow`, `sequenceExhausted`) and `syncRequestsByTick` move from `OutputCollector` into the model. This ends K1b-4's D1.
- **The scoped emitter:** each handler call gets a per-step scope (a lock-protected open flag and the staged list). `LandContext`'s three output closures capture the scope, not the model. The step moves the staged events into `turn.emit` after the handler returns, and closes the scope. A call after that is dropped and counted, asserted in debug. That is a visible behavior change, stated in K2's PR (parent §8).
- **Record drafts** are outputs. `flush` hands them to the recorder's serial sink in step order (TurnActor.swift:897's flush after each step).
- **The in-turn sync phase** stays inside the step and calls the port through the binding token (parent §3.7).

### 4.5 Ports, tokens and the services table (parent §3.1, §3.7)

- **The binding token** (the port plus its `BindingID`) is attached by the entries that need the port. The step checks the `BindingID` against the model's, then calls the port's synchronous in-turn methods.
- **The admission clear** takes a package path, `admitJoiningSessionInStep(…, recordsSyncStream:) -> (JoinAdmission, [SyncStreamDraft])`, so no port call reaches back into the keeper during a step.
- **The callback audit**, before the cut-over commit: grep the adapter for every `keeper.assumeIsolated` and list each with the path that reaches it. One that a step can reach is a stop.
- **The per-player services table** lives on `LiveLandTurns`, keyed by `(PlayerID, EntryID)`. `flush` writes it from the join step's output and removes it on the leave step's output.

### 4.6 Drivers and the result slot

- **The tick and sync loop Tasks** only `send(.tickDue(scheduled, loopEpoch))` and `.syncDue(…)` (parent §3.9). The `.tickDue` step rejects a stale epoch. #762 makes them core timers later.
- **The result slot and `JobCancellation`** (parent §3.2): the slot table in the model, the token's three states, the seal in every step that fills a slot.

## 5. The Behavior I/O question (for the maintainer)

**K2-Q1. May a handler reach `ctx.services` inside a step?**

The core's `Behavior` contract (Machine.swift's doc) says a step is synchronous and deterministic and touches nothing outside the model; anything that waits or does I/O goes out as an effect. After K2, handlers run inside steps, and `ctx.services` lets a handler reach any registered service. That is the one place where today's API and the core's contract disagree (survey §2).

What the repository's handlers do with it today: they note facts into sinks outside the state.
- `InputProbe.noteApplied()` (VisibilityTestLand) is a counter for the benchmark.
- `HeroDefenseStats` is a JSONL stats sink, which GameServer registers for live lands only.
- No repository handler reads a service's answer into state. Resolvers do that (`SimulatedExternalService` in ResolverTestLand), and resolvers run outside steps, as effects.

A service that a handler reads into state breaks replay today already: the record doesn't hold the answer. So the question is what K2 promises, not what it fixes.

| Option | What it means | For a land author | Cost |
|---|---|---|---|
| **(a) A documented exception (recommended for K2)** | Handlers keep `ctx.services`. The docs state the contract: a service used in a handler is synchronous and doesn't block, and nothing it returns may change state; data from outside goes through a resolver. The same status as an `@Internal` field holding a class | Nothing changes | Docs only; K2 keeps "no public change" (parent §8) |
| (b) Observation-only services by type | Handlers see only services that conform to a new marker protocol (say `HandlerSink`), registered as such; others are reachable only from resolvers | A sink adopts the marker; a land that reads a service in a handler moves the read to a resolver | A public break; a marker can't prove a method returns nothing useful, so it states intent rather than enforcing it |
| (c) No services in handlers | `ctx.services` is removed from `LandContext` in handlers. Observation goes out as outputs: a handler stages a note, and `flush` delivers it to a sink registered on the keeper, after the step | Sinks become output consumers; reads move to resolvers | A public break; the purest fit with the core (the Elm and Redux shape: no I/O in `update` or a reducer; effects outside). The flush adds a hop per note |

**Recommendation:** (a) in K2, so the cut-over stays free of public changes. (c) is the clean end state, so I propose a separate before-release issue to decide (b) or (c), with the demo's two sinks as the worked cases. Prior art for (a): Erlang's `gen_server` lets `handle_call` do side effects and relies on convention. For (c): Elm's `update` returns `Cmd`, and Redux keeps side effects in middleware.

## 6. Slicing K2 into PRs (a proposal for Review)

Parent §5 has K2 as one slice. It is the largest one, so this draft proposes three PRs, each building green and changing no behavior on its own:

1. **K2-1, the types:** `KeeperInput`, `KeeperQuery`, `KeeperEffect` and the rest; `extension KeeperModel: TurnMachine`, with `handle` calling the K1b-5 bodies. It is compiled and unit-tested against a `TurnCore` in tests only; the keeper doesn't use it yet. The lint fixture for the facade.
2. **K2-2, the cut-over:** the facade and `KeeperOwner`; every entry forwards to the core; the scoped emitter, the binding token, the services table, the package admission path, the drivers. This is the PR that runs the full host A/B and the harness.
3. **K2-3, the leftovers:** the code paths K2-2 made unreachable on live keepers, each first proven unreachable. K9 still owns the deletions that need K3–K7.

The risk of K2-1: a machine that isn't wired in can drift from the keeper's bodies before K2-2. So K2-2 follows K2-1 without other keeper PRs in between.

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
| Q1 (parent) | The layout: (c) the facade, recommended | the maintainer | K2 |
| K2-Q1 | `ctx.services` in steps (§5): (a) recommended for K2 | the maintainer | K2-2's docs |
| K2-Q2 | Three PRs instead of one (§6) | Review | K2-1 |

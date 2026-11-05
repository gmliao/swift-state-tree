# Keeper state changes only in turns; helpers for the outer layer

Status: plan, rev 2 (2026-11-05). Rev 1's adversarial check: 2 blocking, 5 should; all addressed (see § Changes in rev 2). The maintainer decided the throwing-OnLeave-resolver case: a new `OnLeaveFailed` callback (§ K-b).

## Problem

Actor reentrancy (check → await → act) keeps producing the same bug: a function checks keeper or adapter state, suspends, and acts on the stale check when it resumes. Today's PRs fixed instances one at a time: #137 checks disconnect ownership after `keeper.leave`, #139 guards the initial-sync handover, and #141 re-checks the sender in the append segment and checks `joinSequence` in `discardIfFailedJoin`. A sweep of `Sources/` found 22 more sites (listed below). Re-checks added by hand miss sites. The rule should make the bug unrepresentable where it can, and cheap to guard where it can't.

## The rule

**Keeper state is mutated only inside synchronous turns. Async work is a request that goes out, and its result comes back as a turn input. A suspended function never resumes to mutate keeper state.** The handler of a result input re-reads the current state and validates it with a ticket (a generation captured when the request went out). If the ticket is stale, the input is rejected, not applied.

This isn't new. It is the Elm architecture's `Cmd`/`Msg` split: `update` is pure and synchronous, and effects return as messages. It is also Erlang/OTP's `gen_server`: `handle_call`/`handle_cast` never block, and async work runs elsewhere and arrives back through `handle_info`. Akka's `pipeTo` has the same shape. The docs say so and link these.

**Outside turns** (adapter, transport, router, host, NIO, admin, reevaluation service), state isn't owned by a turn loop. There the rule is: **use the helpers** (below). Make the check and the act one synchronous segment that the compiler enforces, and capture a ticket before every await that precedes an act.

## What turns already cover

The live keeper on the in-turn path (#114) already runs tick, sync-only and tickless input turns with no suspension inside a turn. Pending items run in `(resolvedAtTick, sequence)` order (`readyPendingItemsInOrder`). On tick lands, replay consumes the recorded `resolverOutputs` and `resolvedAtTick` (`LandKeeper.swift` ~730) and never runs resolvers again, so an action is already scheduled as an input bound to its resolver's completion. Tickless lands are never replayed (`runTick` takes the tickless branch before the replay source), so their determinism claims are about live behavior only. The remaining violations are the code after an await that touches other keeper state: the append and its checks, the join's insert and kick, leave's removal before its resolvers, the drain/finalize handlers, and the freeze settle.

## Keeper migrations, in order

For each item: the change, the extra latency, the effect on sync cadence, and the effect on replay determinism.

### K-a. Action resolvers: the result is an input (PR b1)

Client events have no resolvers; their intake has no await between the check and the append (#141) and is unchanged, except for the `.landClosed` intake check (K-e).

- **Today:** intake segment (sender check, `takeNextSequence`), then `await executeResolvers`, then the append segment (#141's re-check, then `pendingItems.append`).
- **Change:** the intake segment captures a ticket and starts the resolvers. Resolver completion calls one synchronous keeper method, `deliverResolved(ticket, sequence, outputs)`, the only code after the await. It validates the ticket and appends the input. **The ticket** is the player entry's generation (`InternalPlayerSession.generation`, replacing `joinSequence` and the client/session compare) and the keeper's lifecycle generation.
- **Rejection rules**, against #141's intake rule:

  | At intake | At delivery | Result |
  |---|---|---|
  | no entry for P (direct callers, before or without a join) | anything | accepted, as today (the ticket records "no entry"; nothing to compare) |
  | P's entry, sender matches | the same entry (same generation) | accepted |
  | P's entry, sender matches | the entry gone, or another generation | rejected, `senderSuperseded` |
  | P's entry, sender is another client/session | — | rejected at intake, `senderSuperseded` (today's rule) |
  | any | the land draining or closed | rejected, `landClosed` (K-e) |
  | system player/client, non-`.live` keeper | — | exempt, as today |

- **Per-session order on tick lands.** If intake started the resolvers and returned, a fast action could be delivered before an earlier slow one from the same session. **The caller still waits for its own delivery** on tick lands too: `handleActionEnvelope` returns after `deliverResolved` (the item is appended), as today. On NIO, one session's messages reach the adapter in order through #112's `InboundTaskChain`, each finishing before the next starts, so one session's actions are appended in send order. Other transports must give the same per-session order (stated with the transport contract in d1). What changes is only who may mutate after the await, not when the caller returns.
- **Latency:** none compared with today. The input is applied in the first turn after its resolvers finish, bound to `resolvedAtTick`, as now.
- **Sync cadence:** unchanged.
- **Replay (tick lands):** the record format is unchanged. A rejected delivery leaves a sequence gap with no record. That's harmless: replay advances via `restoreSequenceWatermark` (resolver throws already leave gaps). Test: a recording with gaps inside the legacy W1–W2 window and between ticks replays with 0 mismatches. Tickless lands aren't replayed.

### K-a2. #88: per-input results on the off path (PR b2)

- Changing `processPendingActions`' return value doesn't fix it: A's item can be applied in B's pass, so A's response must outlive that pass.
- The fix ports the in-turn path's per-sequence result store (`inputTurnResults` / `awaitInputTurn(sequence)`) to the off path. Each tickless caller awaits its own sequence's result, whichever pass applied it.
- This changes the kill switch, so it gets ON/OFF parity tests: the same responses for the same concurrent actions. Plus a held test: two concurrent actions whose resolvers finish in overlapping order.
- Also: `processPendingActions` removes the applied prefix when a handler throws (as `applyInputBatchInTurn` does), so applied inputs aren't re-applied on the next pass. The un-applied remainder's re-run stays #87.

### K-b. Join and leave (PR 4, plan `2026-11-05-join-as-turn-input.md` rev 4): consistency check

Rev 4 already makes OnJoin a turn input with the flip at a committed sync. Against the rule:

- **Resolve first, then one admission segment** (decided in rev 1's check). The join's resolve phase runs OnJoin's resolvers, and, if P has an entry (a kick), that entry's OnLeave resolvers, concurrently. Then one synchronous admission segment:
  - checks both tickets (P's old entry generation, if any; the keeper's lifecycle generation);
  - does the capacity check (K2), the kick (removes the old entry) and the insert;
  - appends OnLeave and OnJoin with the same `resolvedAtTick` and adjacent sequences (OnLeave's lower), so OnLeave applies first;
  - admits the session.

  A resolver failure fails the join before anything changes. If the old entry is already stale (its own disconnect queued an OnLeave), only OnJoin is appended. OnLeave's resolvers aren't skipped. This removes K1 (the insert-before-resolvers gap) and K3 (the legacy kick-old with no identity compare; the legacy `join(playerID:…)` goes through the same segment).
- **Leave as a request**: resolve, then one segment removes the entry and appends OnLeave. This is a plain disconnect, not a kick.
  - **An OnLeave delivery is never rejected for a stale entry**: a leave always ends in OnLeave for the game, even if the player re-joined meanwhile.
  - **P's OnJoin is gated on any outstanding OnLeave of P**, not just a kick's. A join of P while a leave of P is resolving waits for that leave's delivery, then runs its admission segment. Otherwise a slow OnLeave resolver followed by a reconnect would give OnJoin the lower `resolvedAtTick`: OnJoin would apply first and OnLeave would then remove the rejoined player.
  - Held tests: a slow OnLeave resolver followed by a reconnect; a kick with a slow OnLeave resolver.
- **A throwing OnLeave resolver (decided by the maintainer: a new callback).** Today `leave` removes `players[P]` before its resolvers, and on a throw never appends OnLeave: the game state keeps a ghost, and a later kick fails the new join. The change:
  - **A new optional DSL handler, `OnLeaveFailed { state, ctx, error in … }`**, next to `OnLeave` in `Rules` (named like the existing lifecycle DSL in `LandDSL.swift`/`LandBuilder.swift`). It runs **instead of** OnLeave when OnLeave's resolvers throw. It gets the resolver error and has no resolver outputs. OnLeave's own contract is unchanged: it always has its outputs.
  - **Without OnLeaveFailed**, OnLeave runs with empty outputs and `ctx.resolverFailure` set, so a land never keeps a ghost by default.
  - Either way the player is removed from the keeper, and the delivery is a normal lifecycle input: recorded with its sequence and `resolvedAtTick`. Replay consumes the recorded failure and never re-runs the resolver. The error is recorded as a stable code and description (`ResolverFailure { code, description }`), not the raw error.
  - Schema/codegen: lifecycle handlers aren't in the schema (`SchemaGen` lists none), so there's nothing to add there.
  - Tests:
    - a throwing resolver with OnLeaveFailed defined: it runs, and OnLeave doesn't;
    - the same without OnLeaveFailed: OnLeave runs with the flag;
    - a replay of both on a tick land (0 mismatches);
    - a reconnect after it: the join succeeds.
  - It lands with K-b (PR 4).
- **Latency:** a join waits for its resolvers (and a kick's OnLeave resolvers, concurrently) as today. A join behind an outstanding leave of the same player waits for that leave's resolvers. No extra turn before the OnJoin turn; the flip adds rev 4's wait for the next committed sync.
- **Replay (tick lands):** OnLeave and OnJoin are recorded as today, in sequence order. The kick's pair shares a `resolvedAtTick`.
- **`discardIfFailedJoin`:** compares the entry generation (`joinSequence` becomes that generation in PR b1).

### K-c. The firstSync state read (PR 4)

Rev 4's flip takes the joiner's view from the committed sync's end state, inside the turn. The `currentStateLocated()` await in `_syncStateForNewPlayer`, and #139's re-check after it, go away with the legacy firstSync on the in-turn path. Latency is rev 4's: the joiner waits for the next committed sync. Replay: the seed marker is recorded in that turn, which is already rev 4's design.

### K-d. Freeze settle (#129)

A freeze becomes a turn input. The turn captures the state, plans and commits the settle sync, and marks the land frozen in one segment. `debugCycleHoldBeforeEndSync` and the legacy `beginSync`/`endSync` cycle go with layer 3 PR B. Latency: the freeze takes effect at the next turn, normally immediate on an idle keeper. There's no effect on sync cadence (a frozen land doesn't sync). Replay: the freeze isn't a recorded game input, so it doesn't change determinism. The existing ON/OFF parity test of the settled output stays.

### K-e. Drain and finalize, shutdown, the legacy tick (PR b3)

- **Drain/finalize.** `drainAfterIdleCheck` awaits the OnDestroyWhenEmpty and OnFinalize resolvers, then mutates the state (~3340, ~3385). Actions and client events never check `isDraining`, so on tickless lands inputs keep applying across those awaits, even after OnFinalize. The drain also leaves pending items and their waiters. Change:
  - resolve both handlers' resolvers first;
  - then, in one synchronous segment: apply every pending input, or fail it with `.landClosed`, and resume its waiter; then run OnDestroyWhenEmpty and OnFinalize;
  - from the moment the drain starts (`isDraining`, set synchronously today), intake rejects actions (with or without resolvers) and client events with `LandInputRejection.landClosed`, and `deliverResolved` rejects late deliveries the same way.

  Held tests: an action arriving during each finalize resolver await; a pending input with a waiter when the drain starts.
- **K5, `forceShutdown`:** it removes pending items without resuming `inputTurnWaiters`, so a tickless join waiting in `awaitInputTurn` never returns, and the adapter's membership queue stalls. Change: fail **only the waiters whose items are removed** from `pendingItems`, with `.landClosed`. Inputs already applied and waiting for their record (`inputTurnResults`) get their result as usual. The drain does the same.
- **K4, the legacy tick path.** `runTick` checks `tickTask != nil`, awaits the source, `processPendingActions` (which applies and records tick N's inputs), the recorder and the broadcast, then runs the tick handler.
  - Skipping the handler after those awaits would leave a partial tick: inputs applied and recorded, a frame without watermarks, and a replay that runs a handler live didn't.
  - Change: the in-flight tick is single-flight and the drain awaits it before finalizing, so a started tick finishes whole. Equivalently, the drain check is made before `processPendingActions`, so a tick either runs whole or not at all.
  - The ticket is the drain (the lifecycle generation), not `tickTask`, since `stepTickOnce` passes `allowWhenNoTickTask`. Held test: a drain while a tick is suspended in `processPendingActions`.
- **#73 (duplicate tick ids):** can't happen on the in-turn path. A tick is one turn, and `enqueueRecorderSubmission` chains submissions in order. On the legacy path, K4's single-flight tick also prevents `stepTickOnce` and the tick loop from overlapping. Plan: a held test on each path; then close #73 with that evidence.
- **Already single-flight or re-checked in one segment** (the sweep checked them; no change): `initializationTask`, `drainTask`/`DrainFlag`, `debugFreeze`, `flushOutputs`, `scheduleDestroyIfNeeded`.

## Outer-layer helpers (PR a)

The adapter, transport, router, host, NIO, admin and reevaluation service aren't turn-driven. Internal helpers, with no public API change except where an existing public type is reused:

1. **Generation tickets.** The existing `Epoch`/`EpochCounter` (`Support/SingleFlight.swift`, #116) gain a per-key table: `GenerationTable<Key>` with `issue(key) -> Ticket`, `isCurrent(ticket)` and `end(key)`. A `Ticket` carries the key and the `Epoch`. It replaces the ad hoc maps where the semantics match:
   - the adapter's `connectionGenerations` and `endedSessions` checks;
   - the router's session lifetime (#97);
   - `WebSocketTransport`'s `sessionQueues` and generations;
   - the reevaluation run (#100);
   - the keeper's player entry generation (K-a). The keeper's ticket check runs in the delivery input; it uses the same type.
2. **Synchronous check-and-act.** `table.ifCurrent(ticket) { … }` is non-mutating on the table, and its closure is **not `async`**, so the compiler rejects an `await` between the check and the act. A `Task` spawned inside the closure escapes the guard; the doc says so.
   - **A proof type only for small keyed tables:** the router's binding and handshake phase, the transport's session queues, and the adapter's slot release. Their mutators take a `Current<Key>` proof, `~Copyable` and passed `borrowing`, which only `ifCurrent` can make (private init). So those mutations are reachable only through the check.
   - **The closure form plus held tests** for the sync engine's caches and the firstSync commit (decided in rev 1's check: a wrapper there is too invasive).
3. **SingleFlight and lifecycle state.** `SingleFlight` exists (#116). A small `Lifecycle` helper adds a state enum (`idle`, `starting(Task)`, `running`, `stopping(Task)`, `stopped`) set synchronously before the first await, so concurrent `start`/`stop` calls join the in-flight task. A stop during a start waits for the start, then stops. It's used for the host, server, transport and realm start/stop (#101), and for destroy-once (#102).
4. **Forced holds, a test helper.** Library code exposes named hold points through one optional per-instance hook (`holds?.at(.routerJoinAfterLand)`, an enum of points per type), a no-op unless a test installs it, the same cost as today's `setLeaveHook`/`setInitialSyncHoldForTesting`. Tests get a `HoldRegistry` that maps points to `TestGate`s (including "hold only the n-th arrival"), so each converted site gets a held test in a few lines. New sites use it from PR (a). Moving the existing ad hoc hooks onto it is its own PR (a').

The helpers are internal to the package (package access) except `Epoch`/`SingleFlight`, which are public today.

## Retrofit inventory

Each item: status today, and what changes. Sweep IDs (K, A, R, M, W, N, S) refer to the sweep of 2026-11-05.

### Today's sites (PR a converts them to the helpers; no behavior change)
- **#137**, disconnect ownership after `keeper.leave`: stays a membership re-check in one segment, written with `ifCurrent` on the player's session set. Its held test exists.
- **#139**, the handover guard and the re-check after the state read: become the session ticket (captured at admission, checked at the handover and at the commit). This also covers a reused SessionID, which the membership compare doesn't. K-c later removes the read on the in-turn path.
- **#141**, intake re-check and `discardIfFailedJoin`: the re-check becomes K-a's delivery validation, and `joinSequence` becomes the entry generation, both in PR b1 (not in a).

### Join and session (PR d1)
- **#97, ghost join:** `LandRouter.handleJoinRequest` checks `sessionToClient`, then awaits `getLand`/`getOrCreateLand`/`performJoin` before binding (sweep R2, R5).
  - Today: #112's `InboundTaskChain` orders one session's connect, messages and disconnect on NIO, so a client disconnect can't run inside its own join there. A server-initiated close (`WebSocketTransport.closeSession` calls `handleDisconnection` directly) and non-NIO transports still can.
  - Change: the router issues a session ticket at connect. The join captures it, binds with `ifCurrent`, and passes it to `performJoin`, whose admission segment checks it. A dead session's join fails with `disconnected` and undoes its keeper join.
  - Held test: a disconnect during `getOrCreateLand`, and a server close during the join response.
  - Held test: a stale disconnect after a re-admission. The adapter's disconnect is keyed by SessionID and arrives late through the router's `onDisconnect` Task, so a reused SessionID could let it tear down a fast reconnect. The disconnect carries the session ticket it was issued for and is ignored when that ticket is no longer current. NIO mints a UUID per connection, so this is the transport contract's non-NIO case.
- **#98, initial sync owned by player:** fixed for different sessions by #139 (re-check after the read) and #141 (the mark owned per session).
  - The residue (a reused SessionID) is unreachable over NIO. **Transport contract:** a SessionID is unique per connection (`NIOWebSocketServer` gives each a fresh UUID). The contract is documented on `Transport`, and #98 is closed for NIO with that evidence and the existing held tests.
  - A fragile rule to note in the code: the staged firstSync fills the per-player cache only if it's empty (`SyncEngine.swift` ~1207, ~1475). It's correct today only because the handover and disconnect clear the cache first. A comment states the dependency, and a test fails if a stale entry survives a re-join.
- **#99, per-session inbound order:** fixed on NIO by #112 (`InboundTaskChain`).
  - Remaining: the router's "already joined" check before awaits (R1, R4) and the legacy adapter's (A1), reachable through non-NIO transports and server-initiated closes.
  - Change: the router reserves the binding synchronously as `.joining(ticket)` before the first await; a second join on the session is rejected; a failure removes only its own reservation (ticket compare). Legacy: the admission segment rejects an already-joined session.
  - Close #99 for NIO with #112 as evidence, plus these tests.
- **Sweep, adapter:**
  - A2: `_registerSessionImpl` writes the generation after an await. Changed to the ticket.
  - A3: `_onConnectImpl` skips the membership queue. Connect goes through the queue.
  - A1: above.
  - The dead rollback in `finalizeJoinRequest`'s `defer` is removed or made reachable.
- **Sweep, transport:**
  - W1: `sessionQueues` are overwritten and removed by key. Changed to a ticket compare.
  - W2: the stale `serverClosedSessions` flag is keyed by ticket.
  - W4: `registerSession` re-adds a disconnected session. It checks the ticket.
- **Sweep, router:** R3, instance lookup by `LandID` alone (PR d2, with #102).

### Lifecycle (PR d2)
- **#100, reevaluation run:**
  - S1: a cancelled verification task keeps writing `runner`, status and results. Each run gets an `Epoch`, and every write after an await is `ifCurrent(run)`.
  - S2: `stop()` and the two-lock task assignment become one `Lifecycle`; callers stop doing check-then-start outside the lock.
  - S3: `ConcreteReevaluationRunner.step`, single-flight.
- **#101, start/stop state machines:**
  - N1, N2: `NIOWebSocketServer.start`/`shutdown`.
  - N3: `NIOLandHost.run`/`shutdown`, including the `onCancel` task.
  - W3: `WebSocketTransport.stop`, which closes and notifies every session, including ones registered during the stop.
  - `LandRealm.shutdown`.
  - `LandManager.shutdownAllLands` (already has `isShuttingDown`; verify).
  - All of these go through `Lifecycle`.
- **#102, DELETE /admin/lands:** removal becomes destroy-once through `LandManager`'s existing generation-keyed destroy (#116): stop the keeper, disconnect its sessions, then remove the entry by epoch.
  - M2: remove by epoch, not by ID.
  - R3: the router resolves the bound instance by (LandID, epoch), so a disconnect never reaches a recreated instance.
  - N4: `NIOLandServer.shutdown` stops its lands.
  - M1: the drain snapshot is re-checked in the create segment.

### #88 (PR b2)
Tickless action responses to the wrong caller: K-a2 above.

### NIO handler, off-loop state (#144; PR d3)
`WebSocketSessionHandler.send`/`close` read `context`/`isClosed` off the event loop. This isn't actor reentrancy but the same class: loop-confined state is checked on one thread and acted on another. Change: the check and the write run on the loop (`eventLoop.execute`), with handler state behind `NIOLoopBound`. Test: close while a send is in flight, under TSan.

### #142 (investigation, in parallel)
The intermittent `client == server` failure in `TransportAdapterSyncDirtyWindowTests` with in-turn sync off.
1. Reproduce: loop the test under full-suite load, or alongside CPU stress, with `IN_TURN_SYNC=false`.
2. Record the interleaving, then force it with a hold point (helper 4).
3. Find the lost mutation; suspects are a dirty flag cleared, or a follow-up sync dropped after a rejected `beginSync`.
4. Fix it and check in-turn sync too.

The assertion isn't loosened. If it doesn't reproduce in about 200 loops under load, report that with the loop count and keep the issue open.

### Out of scope
#103 (idempotency keys), #104 (deadlines), #61/#113 (back-pressure): a different class. The TS SDK analogs (#143, #145) aren't in this plan.

## PRs and order

- **(a) The rule and the helpers' core** (`Sources/SwiftStateTree/Support`, the adapter's today-sites, CLAUDE.md, AGENTS.md):
  - `GenerationTable`/`Ticket`, `ifCurrent` (with the proof type for small tables), `Lifecycle`, and the hold registry for new sites;
  - converts #137 and #139 (the session ticket);
  - docs: CLAUDE.md and AGENTS.md state the rule as **the target**, with the Elm/`gen_server` references: "keeper state changes only in turns; async results return as inputs; outside turns, use the helpers". Until (b) and (c) land, they name the keeper paths that don't follow it yet.

  About half a day.
- **(a') The hold-registry migration:** the existing ad hoc hooks move onto it. 1–2 hours.
- **(b1) K-a, resolver as input**, with `joinSequence` → entry generation and the rejection table. About half a day.
- **(b2) #88**, per-input results on the off path, with ON/OFF parity. About half a day.
- **(b3) Drain/finalize, K4, K5, #73.** About half a day.
- **(c) PR 4, join as a turn input:** K-b (resolve-first admission, the leave gate, the OnLeave-throw decision) and K-c. It depends on (b1) and (b3), and includes `OnLeaveFailed`. As planned (about 1–1.5 days), with its 7600X runs before merge.
- **(d1–d3) Outer-layer retrofits**, after (a), in parallel with (b) and (c):
  - d1, join and session (#97, #98, #99 and the A/W sweep sites): about half a day;
  - d2, lifecycle (#100, #101, #102, R3, M1/M2, N1–N4, S1–S3): about one day;
  - d3, the NIO handler (#144): 1–2 hours.
- **K-d (freeze, #129)** rides with layer 3 PR B, which removes the legacy cycle.
- **#142**: an investigation alongside (a)/(b), when the build slot allows. 1–3 hours to reproduce or rule out.

Estimates are agent time, from this repo's PR cadence (small PRs 20–80 minutes, large ones about a day), and exclude review rounds.

## Tests

- Every converted or fixed site gets a held test: a hold point at the former await, the competing call issued during the hold, then the gate opened. No sleeps.
- Each fix is mutation-checked (the guard removed, so its test fails).
- PR b1: on a tick land, replay of a recording with rejected deliveries and resolver throws (sequence gaps inside the legacy W1–W2 window and between ticks) gives 0 mismatches. PR b2: ON/OFF parity of tickless responses.
- PR a: a compile-time check that `ifCurrent`'s closure can't await. A test target file that doesn't compile can't live in the suite, so it's documented with the type signature, and the PR shows the diagnostic once.

## Risks

1. **K-a's delivery as the only post-await code.** A resolver Task that outlives the keeper (shutdown) must find the keeper's generation changed and do nothing. Resolver cancellation on shutdown isn't added here.
2. **The leave gate** (K-b) makes a join wait behind its player's outstanding leave. A leave whose resolvers hang delays that player's re-join until they finish; it's bounded by the resolver's own timeout, as today's join behind a kick is.
3. **The kill switch changes in b2** (off-path per-input results). The ON/OFF parity tests are the guard.
4. **The proof type** is used only for small tables. The sync-engine caches rely on the closure form plus held tests, which a later edit could bypass; the doc and CLAUDE.md say so.

## Changes in rev 2 (from rev 1's adversarial check)

| Finding | Where |
|---|---|
| Blocking 1: OnLeave-before-OnJoin covered only the kick; a throwing OnLeave resolver leaves a ghost | K-b: OnLeave deliveries are never rejected for staleness; P's OnJoin is gated on any outstanding OnLeave of P; the throw case is a maintainer decision, (i) recommended |
| Blocking 2: drain/finalize breaks the rule; inputs apply after OnFinalize | K-e: resolve first, one segment that applies or fails every pending input and runs both handlers; a `.landClosed` intake check |
| Should 3: K5 must fail only removed items' waiters | K-e (K5), and the same in the drain |
| Should 4: skipping K4's handler leaves a partial tick | K-e (K4): a single-flight tick the drain awaits, ticketed on the drain |
| Should 5: #88 needs a per-sequence result store | K-a2 (PR b2), with ON/OFF parity; the applied prefix removed on a throw |
| Should 6: K-a must keep per-session order on tick lands | K-a: the caller waits for its own delivery |
| Should 7: the action ticket's rejection rules | K-a's table |
| Half-inputs: true for tick lands only; client events have no resolvers | § What turns already cover; K-a |
| #98's residue is unreachable over NIO | Retrofit inventory: the transport contract, and the fragile cache-fill note |
| Open (a): resolve first | K-b |
| Open (b): proof type for small tables only | Helper 2 |
| Open (c): per-sequence result | K-a2 |
| Nits: `ifCurrent` non-mutating, a spawned Task escapes; the docs state a target until (b)/(c); `joinSequence` converted in b1; the hold migration as its own PR | Helper 2, PRs (a), (a'), (b1) |
| PR split | § PRs and order |

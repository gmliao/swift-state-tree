# Keeper state changes only in turns; helpers for the outer layer

Status: plan, rev 1 (2026-11-05). For the adversarial check before any code.

## Problem

Actor reentrancy (check → await → act) keeps producing the same bug: a function checks keeper or adapter state, suspends, and acts on the stale check when it resumes. Today's PRs fixed instances one at a time: #137 checks disconnect ownership after `keeper.leave`, #139 guards the initial-sync handover, and #141 re-checks the sender in the append segment and checks `joinSequence` in `discardIfFailedJoin`. A sweep of `Sources/` found 22 more sites (listed below). Re-checks added by hand miss sites. The rule should make the bug unrepresentable where it can, and cheap to guard where it can't.

## The rule

**Keeper state is mutated only inside synchronous turns. Async work is a request that goes out, and its result comes back as a turn input. A suspended function never resumes to mutate keeper state.** The handler of a result input re-reads the current state and validates it with a ticket (a generation captured when the request went out). If the ticket is stale, the input is rejected, not applied.

This isn't new. It is the Elm architecture's `Cmd`/`Msg` split: `update` is pure and synchronous, and effects return as messages. It is also Erlang/OTP's `gen_server`: `handle_call`/`handle_cast` never block, and async work runs elsewhere and arrives back through `handle_info`. Akka's `pipeTo` has the same shape. The docs say so and link these.

**Outside turns** (adapter, transport, router, host, NIO, admin, reevaluation service), state isn't owned by a turn loop. There the rule is: **use the helpers** (below). Make the check and the act one synchronous segment that the compiler enforces, and capture a ticket before every await that precedes an act.

## What turns already cover

The live keeper on the in-turn path (#114) already runs tick, sync-only and tickless input turns with no suspension inside a turn. Pending items run in `(resolvedAtTick, sequence)` order (`readyPendingItemsInOrder`), and replay consumes the recorded `resolverOutputs` and `resolvedAtTick` (`LandKeeper.swift` ~730). It never runs resolvers again. So an action is already scheduled as an input bound to its resolver's completion. The remaining violations are the code after an await that touches other keeper state (the append and its checks, the join's insert and kick, the freeze settle).

## Keeper migrations, in order

For each item: the change, the extra latency, the effect on sync cadence, and the effect on replay determinism.

### K-a. Action (and client event) resolvers: the result is an input (PR b)

- **Today:** intake segment (sender check, `takeNextSequence`), then `await executeResolvers`, then the append segment (#141's re-check, then `pendingItems.append`).
- **Change:** the intake segment captures a ticket: the player entry's generation (replaces `joinSequence` and the client/session compare) and the keeper's lifecycle generation (draining). It starts the resolvers and returns. Resolver completion calls one synchronous keeper method, `deliverResolved(ticket, sequence, outputs)`, the only code after the await. It validates the ticket (`LandInputRejection.senderSuperseded` or `.landClosed`) and appends the input. The caller waits for its own input's response (`awaitInputTurn(sequence)`), on both paths.
- **Latency:** none compared with today. The input is applied in the first turn after its resolvers finish, bound to `resolvedAtTick`, as now.
- **Sync cadence:** unchanged (the turn that applies it syncs as today).
- **Replay:** the record format is unchanged: `resolverOutputs` and `resolvedAtTick` are recorded on the applied item, and replay feeds the recorded item. One case to verify: an input rejected at delivery has a sequence but no record, leaving a gap. Resolver throws already leave gaps today; a test confirms replay tolerates them (0 mismatches).
- **Also fixes #88** (tickless action responses to the wrong caller). The in-turn path already answers per input (`awaitInputTurn(sequence)`). The off path's `processPendingActions()` returns the last item's response to whoever called it. With per-sequence responses on both paths, each caller gets its own. A held test runs two concurrent actions whose resolvers finish in overlapping order.
- **K5 (sweep):** `forceShutdown` removes pending items without resuming `inputTurnWaiters`, so a tickless join waiting in `awaitInputTurn` never returns, and the adapter's membership queue stalls. In the shutdown segment, the waiters are failed with `.landClosed`.

### K-b. Join (PR 4, plan `2026-11-05-join-as-turn-input.md` rev 4): consistency check

Rev 4 already makes OnJoin a turn input with the flip at a committed sync. Against the rule, these remain:
- **K1:** the OnJoin resolver await sits between the insert and the append. The join becomes K-a's shape: resolve first, then one admission segment does the capacity check, kick, insert, OnJoin append and admission, validated by a ticket (the old entry's generation, the keeper's generation).
- **K2:** the capacity check goes stale across the kick's `leave` await. It moves into the admission segment.
- **K3:** the legacy `join`'s kick-old has no identity compare. The same admission segment handles it; the legacy `join(playerID:…)` goes through it.
- **The kick's OnLeave.** Today the join awaits the whole `leave` (including OnLeave resolvers) before inserting, so OnLeave is appended first. Under the rule, the admission segment allocates both sequences (OnLeave's lower) and removes the old entry. OnLeave's resolvers run as a request like K-a. **OnJoin isn't delivered before OnLeave** (OnJoin's delivery waits for OnLeave's), so the `(resolvedAtTick, sequence)` order still applies OnLeave first. This is the one ordering rule new to PR 4; it gets a held test (OnLeave's resolver slower than OnJoin's).
- **Latency:** a join waits for its resolvers as today. No extra turn before the OnJoin turn. The flip adds rev 4's wait for the next committed sync, already accounted there.
- **`discardIfFailedJoin`:** compares the entry generation (the `joinSequence` it compares today becomes that generation).

### K-c. The firstSync state read (PR 4)

Rev 4's flip takes the joiner's view from the committed sync's end state, inside the turn. The `currentStateLocated()` await in `_syncStateForNewPlayer`, and #139's re-check after it, go away with the legacy firstSync on the in-turn path. Latency is rev 4's: the joiner waits for the next committed sync. Replay: the seed marker is recorded in that turn, which is already rev 4's design.

### K-d. Freeze settle (#129)

A freeze becomes a turn input. The turn captures the state, plans and commits the settle sync, and marks the land frozen in one segment. `debugCycleHoldBeforeEndSync` and the legacy `beginSync`/`endSync` cycle go with layer 3 PR B. Latency: the freeze takes effect at the next turn, normally immediate on an idle keeper. There's no effect on sync cadence (a frozen land doesn't sync). Replay: the freeze isn't a recorded game input, so it doesn't change determinism. The existing ON/OFF parity test of the settled output stays.

### K-e. Other keeper awaits that mutate afterwards (sweep)

- **K4, legacy tick path:** `runTick` checks `tickTask != nil`, awaits the source, `processPendingActions`, the recorder and the broadcast, then runs the tick handler and sets `lastCommittedTickId`, with no re-check. A drain can start meanwhile, and the handler runs during or after finalize. This is the legacy path only, removed by layer 3 PR B, but it's the kill switch until then. A ticket (the keeper's lifecycle generation) is captured before the awaits and checked before the handler; on a mismatch the tick is skipped. Held test.
- **#73 (duplicate tick ids):** the recorder opens a second frame for tick N when tick N's post-handler awaits resume after tick N+1 opened its frame. That's reachable only with the tick loop and `stepTickOnce` running at once. On the in-turn path a tick is one turn with no post-handler await, so this can't happen. On the legacy path, `stepTickOnce` is made single-flight against the tick loop. Plan: first reproduce it on each path with a held test. Close it for the in-turn path with that evidence, and fix the legacy path with the single-flight.
- **`initializationTask`, `drainTask`/`DrainFlag`, `debugFreeze`, `flushOutputs`, `scheduleDestroyIfNeeded`:** already single-flight or re-checked in one segment (the sweep checked them). No change.

## Outer-layer helpers (PR a)

The adapter, transport, router, host, NIO, admin and reevaluation service aren't turn-driven. Internal helpers, with no public API change except where an existing public type is reused:

1. **Generation tickets.** The existing `Epoch`/`EpochCounter` (`Support/SingleFlight.swift`, #116) gain a per-key table: `GenerationTable<Key>` with `issue(key) -> Ticket`, `isCurrent(ticket)` and `end(key)`. A `Ticket` carries the key and the `Epoch`. It replaces the ad hoc maps where the semantics match:
   - the adapter's `connectionGenerations` and `endedSessions` checks;
   - the router's session lifetime (#97);
   - `WebSocketTransport`'s `sessionQueues` and generations;
   - the reevaluation run (#100);
   - the keeper's player entry generation (K-a). The keeper's ticket check runs in the delivery input; it uses the same type.
2. **Synchronous check-and-act.** `table.ifCurrent(ticket) { (proof) -> R in … }`, where the closure is **not `async`**, so the compiler rejects an `await` between the check and the act. The guarded state is wrapped so that its mutators take a `Current<Key>` proof value, which only `ifCurrent` can make (private init). That makes the guarded mutations reachable only through the check, where practical:
   - the router's binding and handshake phase;
   - the adapter's per-player cache commit, firstSync commit and slot release;
   - the transport's session queue.

   Where a wrapper is too invasive, the site gets the closure form plus a held test, and the plan's PR lists it.
3. **SingleFlight and lifecycle state.** `SingleFlight` exists (#116). A small `Lifecycle` helper adds a state enum (`idle`, `starting(Task)`, `running`, `stopping(Task)`, `stopped`) set synchronously before the first await, so concurrent `start`/`stop` calls join the in-flight task. A stop during a start waits for the start, then stops. It's used for the host, server, transport and realm start/stop (#101), and for destroy-once (#102).
4. **Forced holds, a test helper.** Library code exposes named hold points through one optional per-instance hook (`holds?.at(.routerJoinAfterLand)`, an enum of points per type), a no-op unless a test installs it, the same cost as today's `setLeaveHook`/`setInitialSyncHoldForTesting`. Tests get a `HoldRegistry` that maps points to `TestGate`s (including "hold only the n-th arrival"). Each converted site gets a held test with a few lines. The existing ad hoc hooks move onto it.

The helpers are internal to the package (package access) except `Epoch`/`SingleFlight`, which are public today.

## Retrofit inventory

Each item: status today, and what changes. Sweep IDs (K, A, R, M, W, N, S) refer to the sweep of 2026-11-05.

### Today's sites (PR a converts them to the helpers; no behavior change)
- **#137**, disconnect ownership after `keeper.leave`: stays a membership re-check in one segment, written with `ifCurrent` on the player's session set. Its held test exists.
- **#139**, the handover guard and the re-check after the state read: become the session ticket (captured at admission, checked at the handover and at the commit). This also covers a reused SessionID, which the membership compare doesn't. K-c later removes the read on the in-turn path.
- **#141**, intake re-check and `discardIfFailedJoin`: the re-check becomes K-a's delivery validation (PR b), and `joinSequence` becomes the entry generation.

### Join and session (PR d1)
- **#97, ghost join:** `LandRouter.handleJoinRequest` checks `sessionToClient`, then awaits `getLand`/`getOrCreateLand`/`performJoin` before binding (sweep R2, R5).
  - Today: #112's `InboundTaskChain` orders one session's connect, messages and disconnect on NIO, so a client disconnect can't run inside its own join there. A server-initiated close (`WebSocketTransport.closeSession` calls `handleDisconnection` directly) and non-NIO transports still can.
  - Change: the router issues a session ticket at connect. The join captures it, binds with `ifCurrent`, and passes it to `performJoin`, whose admission segment checks it. A dead session's join fails with `disconnected` and undoes its keeper join.
  - Held test: a disconnect during `getOrCreateLand`, and a server close during the join response.
- **#98, initial sync owned by player:** fixed for different sessions by #139 (re-check after the read) and #141 (the mark owned per session).
  - Remaining: a reused SessionID, and `populateCacheIfNeeded` keeping a stale entry. The firstSync now commits staged caches in one segment, so verify that the stale entry is gone.
  - Change: the session ticket above. Verify each part with a held test, then close the issue with evidence.
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

### #88 (PR b)
Tickless action responses to the wrong caller: K-a above.

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
  - `GenerationTable`/`Ticket`, `ifCurrent` with the proof type, `Lifecycle`, and the hold registry;
  - converts #137 and #139 (the session ticket) and `joinSequence`;
  - docs: "keeper state changes only in turns; async results return as inputs; outside turns, use the helpers", with the Elm/`gen_server` references.

  About half a day.
- **(b) Resolver as input** (keeper): K-a with #88 and K5, K4, and #73's reproduction and fix. It replaces #141's append re-check with the delivery validation. About one day.
- **(c) PR 4, join as a turn input**, on (a) and (b): K-b and K-c per rev 4, plus the OnLeave-before-OnJoin delivery rule. As planned (about 1–1.5 days), with its 7600X runs before merge.
- **(d) Outer-layer retrofits**, in parallel with (b) and (c) once (a) lands:
  - d1, join and session (#97, #98, #99 and the A/W sweep sites): about half a day;
  - d2, lifecycle (#100, #101, #102, R3, M1/M2, N1–N4, S1–S3): about one day;
  - d3, the NIO handler (#144): 1–2 hours.
- **K-d (freeze, #129)** rides with layer 3 PR B, which removes the legacy cycle. It's listed here so it isn't lost.
- **#142**: an investigation alongside (a)/(b), when the build slot allows. 1–3 hours to reproduce or rule out.

Estimates are agent time, from this repo's PR cadence (small PRs 20–80 minutes, large ones about a day), and exclude review rounds.

## Tests

- Every converted or fixed site gets a held test: a hold point at the former await, the competing call issued during the hold, then the gate opened. No sleeps.
- Each fix is mutation-checked (the guard removed, so its test fails).
- PR b: replay of a recording with rejected deliveries and resolver throws gives 0 mismatches; ON/OFF parity of applied inputs.
- PR a: a compile-time check that `ifCurrent`'s closure can't await. A test target file that doesn't compile can't live in the suite, so it's documented with the type signature, and the PR shows the diagnostic once.

## Risks and open questions for the check

1. **K-a's delivery as the only post-await code.** A resolver Task that outlives the keeper (shutdown) must find the keeper's generation changed and do nothing. Resolver cancellation on shutdown is not added here.
2. **The OnLeave-before-OnJoin delivery rule** (K-b) is new. Without it, a slow OnLeave resolver lets OnJoin apply first. Is gating OnJoin's delivery on OnLeave's enough, or should a kick's OnLeave skip resolvers (it has the entry's data)?
3. **The proof-type wrapper** may be too invasive for the adapter's cache and slot state. Fallback: the closure form plus a held test per site, listed in the PR.
4. **#88's off-path fix** changes `processPendingActions`' return contract for internal callers. All of them are in the keeper; the change is mechanical.
5. **Ticket vs membership compare for #98:** the session ticket must be issued at admission (not connect), or a re-join on the same connection keeps the old ticket. Decided: issued at admission, ended at disconnect and supersede.

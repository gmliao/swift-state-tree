# Disconnect grace: keep a disconnected player so a reconnect keeps its state

Status: open (#334). The design note, with the maintainer's choices settled (§ 10, D1–D5 as recommended, 2026-11-09). Revision 2 took in Review's first pass: the expiry's leave carries the entry's last IDs, the public API and wire section (§ 9), the sync-stream record across a reattach, the timer's lifetime and more tests. Revision 3 rewrites § 5-8 for the maintainer's D6 (B), 2026-11-09: the keeper owns the detached state and the expiry, as turns. There is no code; implementation waits for a build slot.

Line numbers are from `exp/next` at 357e0c32.

## 1. Problem

When a connection ends, the player leaves at once: `OnLeave` runs, and GameDemo's `OnLeave` deletes the player. A client that reconnects seconds later always comes back as a new player, so it loses its position, role and score. That holds even for an authenticated client under the same player ID. It covers every disconnect: a phone switching networks, a short signal loss, a pong timeout, and the server's own closes (4008 send backlog, 4010 slow consumer, 4011 unresponsive, 4012 unencodable view).

Since #344, a resync is done in place: a lagging client gets a fresh snapshot on the same connection. So a resync is no longer a leave and join. The issue text predates this.

## 2. Today's leave path

There is no leave message (`MessageKind`, `Sources/SwiftStateTree/Sync/TransportMessage.swift:15-22`), so every leave is a disconnect.

1. **Transport.** `onDisconnect(sessionID:clientID:)` (`Sources/SwiftStateTreeTransport/Transport.swift:144`) carries no close code or reason.
2. **Adapter, queued.**
   - `_onDisconnectImpl` puts `handleDisconnectQueued` on the land's membership queue (`TransportAdapter.swift:1303-1314`). That queue is one serial tail per adapter, so per land (`enqueueMembership`, `:2754-2763`).
3. **Adapter, synchronous part** (`:1316-1350`). It ends the session's generation, join attempt, inbound drain, session ticket and sync-lag entry. It ends the action-response tickets and cancels the response tasks, which cancels their jobs. It then invalidates the player's membership, which drops queued `.player` events, and unregisters the session.
4. **Keeper.** `keeper.leave(playerID:clientID:sessionID:)` (`:1355`):
   - `LandKeeper.leave` (`LandKeeper.swift:2255-2391`) matches the entry by client ID and recorded session ID. It removes it (`players.removeValue`, `:2287`) and cancels the entry generation's action jobs (`cancelActionJobs(ofEntryGeneration:)`, `:2151`).
   - **OnLeave runs here.** It takes a sequence, runs OnLeave's resolvers under the deadline (`:2306-2340`) and appends a recorded `.leave` lifecycle input (`:2354-2368`).
   - On a tickless land, it waits for the input turn. Then `scheduleDestroyIfNeeded()` arms the empty-land timer (`:4584-4597`).
5. **Adapter, after the await** (`:1367-1393`). If the player has no other session, it clears the sync cache and firstSync mark, records a sync-stream clear, and releases the player slot.

A rejoin today is a new member:
- The join decides the player ID (`preparePlayerSession`, `TransportAdapter.swift:1842-1846`): the JWT's player ID first, then the join message's, then a guest ID, then the session ID.
- On a land without authentication, any client can name any player ID. The JWT check (`JoinIdentityRejection`) applies only on lands that authenticate.
- If the player is still a member, the join kicks the old client through `leave` (newest wins, #92: `LandKeeper.swift:1564-1570`, and `:1366-1372` on the legacy path), so OnLeave and then OnJoin run.
- The keeper already tolerates an entry without a client: `InternalPlayerSession.clientID` is optional (`:4772-4795`), and `isFirst = playerSession.clientID == nil` gates OnJoin (`:1579`, `:1604`; `:1375`, `:1392` on the legacy path). The detached state can't reuse a nil client as its mark, though: a reattach would then count as a first join and run OnJoin. It needs its own flag (§ 3).

## 3. Proposed model

A player entry gets a third state between member and gone: **detached**.

- **attached → detached.** A disconnect that enters the grace (§ 10, D2) detaches the entry. This happens in a keeper turn: no OnLeave, and no player-state change by the framework. The entry keeps its player-state data (device ID, metadata, services), its player slot, and its place in `maxPlayers`.
  - It also keeps its **last client ID and session ID** (`clientID`, `lastSessionID`), and gets a separate `detached` mark. A nil client can't be the mark: `isFirst` would then treat a reattach as a first join.
  - Those last IDs are what the expiry's OnLeave runs with, live, and what its `.leave` input records (§ 6).
- **detached → attached.** A rejoin within the grace that presents valid proof (§ 4) reattaches the entry. OnJoin doesn't run, a new entry generation is taken, and the client gets a firstSync.
- **detached → gone.** At the grace's end, the normal leave runs, with the entry's last client and session IDs: OnLeave, the recorded `.leave` input, the slot release and the empty-land timer.

The grace is off by default, so a land that doesn't opt in behaves exactly as today.

## 4. What a reconnect presents

- **A server-issued reconnect token.**
  - It's in the join response: a new optional `reconnectToken` field in `TransportJoinResponsePayload` (`TransportMessage.swift:174`), sent only when the land has a grace.
  - It's 128 random bits. The server stores it on the entry, bound to (land ID, player ID, entry generation).
  - It's single-use: it's consumed when the reattach is admitted. A reattach issues a new token.
  - The client sends it back in a new optional `reconnectToken` field of `TransportJoinPayload` (`:146`), together with the land instance ID and the player ID.
- **Identity.** The player ID the join resolves to (`preparePlayerSession`) must equal the detached entry's.
  - On a land that authenticates, that already means the same JWT subject.
  - On a land that doesn't, the player ID is a free claim, so the token is what proves it (§ 10, D5).
- **No valid proof.** The join is handled as today: newest wins. If the player ID names a detached entry, that entry leaves (OnLeave), and a new member joins (OnJoin). So the grace adds no hijack path that the free player-ID claim doesn't already give.
- **CanJoin.** It runs on a reattach, as it does on today's reconnection (`isReconnection`, `:1550`, skips only the `maxPlayers` check). A land can then refuse a banned player's reattach.

## 5. The player during the grace

The keeper owns the detached entry, its token and its grace timer (D6 (B)). The adapter keeps only what is per connection, and the player slot until the keeper's leave notification (§ 7).

- **State.** It is untouched. The framework doesn't write game state. Ticks keep running, and handlers see nothing new, because `LandContext` has no connection list. Whatever OnJoin added stays.
- **Actions and client events.** There are none: there's no session. The detach turn cancels the jobs of the entry generation, as a leave does today (`cancelActionJobs`). Their responses couldn't reach the client anyway, since the action-response tickets end at the disconnect. After a reattach, the client resends what it needs.
- **Server events.**
  - `.session(old)` targets are dropped, as today.
  - `.player(id)` events emitted during the grace are dropped, not buffered: the firstSync at the reattach carries the state, and events are transient. Buffering would need a bound and a replay rule, which v1 skips.
- **Sync.** At the disconnect, the adapter clears the player's sync cache and firstSync mark, as today. That's what makes the reattach's sync a firstSync (the snapshot path `syncStateForNewPlayer` already uses). `.perPlayer` fields are part of the state and come back in that snapshot.
- **The adapter at a disconnect that detaches.** It does today's per-connection teardown (the session's generation, tickets, inbound drain, sync-lag entry and pending action responses; `TransportAdapter.swift:1316-1350`) and the sync-cache clear, and keeps the player slot. It then submits the detach to the keeper instead of the leave.
- **The empty-land timer.** `scheduleDestroyIfNeeded` (`:4584-4585`) checks `players.isEmpty`. A detached entry keeps the land alive until its grace ends. Both timers are the keeper's. Worst case: a land outlives its last connection by the grace plus OnLeave's resolvers plus `destroyWhenEmptyAfter`.
  - The empty timer must not start while a leave is pending. The expiry turn removes the entry before OnLeave's resolvers return, so arming the timer there (with `players.isEmpty` its only guard) would let a `destroyWhenEmptyAfter` shorter than the resolver deadline destroy the land before the leave's result turn: OnLeave would never apply, and no `.leave` would be recorded, the replay gap § 6 closes. So the guard becomes `players.isEmpty && pendingLeaves.isEmpty`, and the leave's apply turn (not the expiry turn) arms the timer.
- **A drain or shutdown during the grace.** A detached entry is dropped without OnLeave, as a connected player is at a drain today. The keeper cancels every grace timer when it starts destroying the land (§ 7).
- **A drain or shutdown while a leave is pending.** The pending leave's OnLeave is dropped, as today when the land starts closing during OnLeave's resolvers (`LandKeeper.swift:2344-2352`: logged, and counted with `onLeaveDropped`); its sequence is a gap replay steps over. The joins parked behind it fail as a drain's joins do (`JoinError.landShuttingDown`).

## 6. Sync lag, closes, replay and recording

**Which closes enter the grace (§ 10, D2).**
- The adapter starts 4008, 4010, 4011 and 4012 itself (`transport.closeSession(_, with:)`, `Transport.swift:63-73`). So it can note a pending close reason per session before `onDisconnect` arrives.
- A disconnect the server didn't start (TCP loss, pong timeout, a client close) arrives with no reason. Telling a deliberate client close (1000) from a dropped one (1006) needs the close code passed through `onDisconnect`. That's a protocol change, with a default overload for existing transports (§ 9).
- **v1 includes that close code** for the NIO transport, so D2 holds as decided: a 1000 leaves at once. Only a transport that reports no code (one that doesn't adopt the new overload) falls back to the interim rule below D2, where every disconnect the server didn't start enters the grace. This narrows the interim rule to transports outside this repository (§ 10, D2).

**Sync lag (#344).**
- `syncLag` is per session and removed at the disconnect (`TransportAdapter.swift:1332`), so a reattach starts fresh tracking with a firstSync. That's what a 4010 or 4011 client needs.
- The slow-consumer window counts resyncs per session, though. A client that is simply too slow would loop: 4010, then a reattach, then 4010 again. Only the reattach limit (§ 10, D4) bounds that loop.
- 4012 means the server can't encode this player's view, and a reattach's firstSync would most likely fail the same way. So a 4012 should leave at once.

**Recording and replay.**
- The detach and the reattach are not recorded inputs in the recommended option, D3 (a). Replay then sees what the inputs say:
  - the player's OnJoin;
  - its actions, with the session and client IDs recorded on each input, so the new IDs after a reattach are just values;
  - one `.leave`, at the grace's end.
- **The expiry's `.leave` carries concrete IDs.** Replay applies a recorded `.leave` only when it has a player, client and session ID (`LandKeeper.swift:3174-3196`: `guard let playerID, let clientID, let sessionID, let handler else { break }`). A `.leave` recorded with nil IDs would be skipped silently in replay: no OnLeave, and the state diverges. So the expiry uses the detached entry's last client and session IDs, both in the live OnLeave's context and in the recorded input, and an OnLeave that reads `ctx.clientID` or `ctx.sessionID` sees the same values in both.
- The recorded leave's `resolvedAtTick` is the tick at the expiry, not at the disconnect. A disconnect's timing is wall-clock today too, so determinism doesn't change. The reevaluation docs need one line: the leave is recorded when the grace ends.
- If OnDisconnect and OnReconnect hooks are chosen (D3 (c)), they become new recorded lifecycle kinds (a record format minor bump, 3.x), and replay must apply them like `.join` and `.leave`.
- **The sync-stream record (`recordsSyncStream`).** Today's disconnect records a `clear` marker for the player (`recordSyncStreamClear(playerID, outsideTurn: true)`, `TransportAdapter.swift:3650`, called after `:1360`), and the next join's firstSync a `seed` marker. A detach records the same `clear`, and the reattach's firstSync the same `seed`. What changes is that no `.join` and `.leave` input sits between them: the player stays a member. The in-turn record and the replay's sync-stream check must accept a `seed` for a player who is a member throughout, after its own `clear`. That is to be confirmed in code, and test 10 runs with `recordsSyncStream` on and off.
- Replay viewers (`mode == .reevaluation`) never get a grace: they run no OnJoin and no OnLeave (`:2291-2295`).

## 7. Turns and reentrancy

The design follows the maintainer's rule for every data path: **the phase-separated turn**. A keeper state change happens only inside a synchronous turn, with no `await` between its check and its write; async work is a request whose result comes back as a turn input; and what a turn produces for the transport is an output, emitted after the turn commits (CLAUDE.md § Reentrancy, `Notes/plans/2026-11-05-reentrancy-helpers.md`). The grace's paths, one by one:

- **The detach is a turn input.** The adapter submits it from its membership queue with the session it ended. The detach turn, in one segment, checks that the entry is the session's (client ID, `lastSessionID` and entry generation) and still attached, and checks D4's reattach count. Under the limit, it marks the entry `detached`, keeps its last IDs, cancels the generation's action jobs and arms the grace timer. Over the limit, it is the expiry turn below, at once.
- **The timer only enqueues an input.** The grace timer is a task that sleeps for the grace and then enqueues an expiry input (player ID, entry generation) and schedules the input drain. It never reads or writes keeper state from its own task. It captures the keeper weakly, and the keeper cancels every grace timer when its destruction starts. Otherwise a sleeping task of up to the grace (30 s in GameDemo) keeps a destroyed land alive, which is what #350's release tests catch.
- **The expiry is a synchronous turn.** In one segment:
  - it checks the entry generation and the `detached` mark (a mismatch is a no-op: a reattach or a newer entry got there first);
  - it removes the entry;
  - on a land without OnLeave resolvers, it appends the `.leave` input with the entry's last client and session IDs, applies OnLeave and records the leave, with no `await`.

  OnLeave's resolvers, when declared, are a request: the expiry turn issues it, with a ticket for the removed entry's generation, and the resolvers' result comes back as a turn input whose turn appends, applies and records the `.leave`. That's the request → result-as-turn-input shape actions use since the action completion queue (`startActionJob`, `completeAction`). Today's leave still awaits its resolvers inline (`LandKeeper.swift:2306-2340`), one of the paths CLAUDE.md lists as not yet in turns, and the expiry doesn't copy that.
- **The leave's result turn always arrives.** OnLeave's resolver request ends on success, on a resolver failure, on the resolver deadline (the race returns at the deadline even when a resolver ignores cancellation; `ResolverExecutor.swift:107-160`) and on the keeper's cancellation at a drain. Every one of those comes back as the result turn. On success it applies OnLeave; otherwise the leave is dropped as today (`onLeaveDropped`), the `.leave` sequence is a gap, and either way the pending leave ends and the parked joins apply. The one exception is `RESOLVER_TIMEOUT_MS=0`, which disables the deadline: a resolver that never ends then holds the player's next join forever. Today it holds the land's whole membership queue in the same case, so this is no worse, but the code PR documents it.
- **A pending leave holds the player's next join.** Between the expiry turn and its `.leave` apply (OnLeave's resolvers running), the keeper keeps a pending leave for the player ID. A join for that player ID (a fresh join, or a reattach that fell back to one) is a turn input that, while a pending leave exists, is parked as an input that applies after the leave's apply turn. So OnLeave always applies before a later OnJoin of the same player ID; it never deletes a newly joined player. Today the membership queue gives that order; here, two turns and a recorded pending state give it.
- **A reattach is a turn input.** Its admission turn (the keeper segment that inserts or reattaches, `joinReportingAdmission`'s insert segment) validates its ticket: the token's player ID, land and entry generation must equal the current entry's, and the entry must still be `detached`. Then, in the same segment, it clears `detached`, takes a new entry generation, consumes the token and issues a new one, cancels the grace timer and counts the reattach for D4. Otherwise it is a fresh join (newest wins, and the pending-leave rule above).
- **The expiry and a reattach serialize because both are turns** (Review's condition, pinned). The reattach re-checks `detached` and the generation in its own admission turn, and the expiry re-checks them in its turn; whichever turn applies first wins, and the other sees a generation that isn't its own. There's no lock and no timing assumption. A reattach that is mid-admission on the adapter's membership queue (its CanJoin resolvers running) hasn't reached its turn yet, so an expiry that applies in between ends the entry, and the reattach then falls back to a fresh join.
- **The leave notification is an output.** After the expiry's `.leave` turn commits, the keeper emits `playerLeft(playerID, entryGeneration)` to its transport (`LandKeeperTransport`, a new requirement with a no-op default), like the sync output: the keeper never awaits the transport inside the turn. The adapter handles it outside the turn, on its membership queue: it releases the player slot (`membershipCoordinator.releasePlayerSlot`, `TransportAdapter.swift:1382`) only when the generation names the entry it admitted last for that player (the adapter keeps the generation each admission returned), and drops a stale notification. There's no adapter grace timer and no cross-layer ticket.
- **Newest wins during the detach (#92).** A reattach is admitted through the same membership queue and admission as a join, so the join-pending phase (#224) and the in-turn flip (#69) apply unchanged. Two reattaches with one token: the first consumes it in its turn, and the second's turn sees a consumed token and becomes a fresh join, which supersedes as today.

## 8. Tests (holds, not timing)

Every gate and hold key comes from `KeyedGates.freshKey()` or `fresh` (#358). A new keeper hold point, `.graceExpiry` in `LandKeeperHoldPoint`, sits between the expiry input's enqueue and its turn, so no test sleeps for the grace and a test can order a turn before or after the expiry.

1. **Expiry racing a reattach, reattach first.** Hold at `.graceExpiry` (the input is enqueued, its turn not applied), reattach, then release. Expected: the reattach's turn wins; the expiry turn sees a newer generation and is a no-op; no OnLeave, no `.leave`, no leave notification.
2. **The same race, expiry first.** Hold the reattach at the keeper's `.join` hold point (after its checks, before its admission turn), release `.graceExpiry`, then release the reattach. Expected: the expiry turn removes the entry; the reattach's turn sees no detached entry and becomes a fresh join: OnLeave, then OnJoin, and the join response says it wasn't a reattach.
3. **An action job in its resolvers at the detach.** Hold at `.actionComplete`, disconnect, then release. Expected: the job is rejected, not delivered; its slot is read; no cap slot leaks.
4. **A reattach in the join-pending phase (#224) and the in-turn flip (#69).** Hold the reattach before its flip, and send frames. Expected: they are deferred and applied in order after the flip, as for a join.
5. **Two reattaches with one token.** Hold the first at `.join`, let the second through, then release the first. Expected: one reattach wins in its turn; the other becomes a fresh join and supersedes it.
6. **A drain during the grace.** With a detached entry and its timer armed, call `shutdownAllLands()`. Expected: the timer is cancelled and enqueues nothing, `transportCallsAfterDestruction == 0`, and the land is released (`waitUntilReleased`, as in #350's tests).
7. **Close kinds.** A 4012 leaves at once. A 4010 or 4011 detaches, and a reattach gets a firstSync. A deliberate client close (1000) leaves at once.
8. **The reattach limit (D4).** Past the limit, the detach turn is the expiry turn at once.
9. **The empty land.** With only detached players, there's no destroy until the grace ends. After it, the empty timer runs.
10. **Replay.** Record a detach, a reattach, actions and an expiry. Expected: the replay verifies with 0 mismatches; exactly one `.leave` is recorded, at the expiry, with the entry's last client and session IDs; and the replayed OnLeave *ran*, with those IDs in its context (a test land's OnLeave records the IDs it saw). Run in both in-turn sync modes, and with `recordsSyncStream` on and off.
11. **The default.** With the grace off, the existing leave and join tests pass unchanged.
12. **A join while the expiry's OnLeave resolvers run.** Hold OnLeave's resolvers (a test resolver on a gate), then join the same player ID, with or without a token. Expected: the join is parked; the leave's result turn applies OnLeave; then the join applies OnJoin. The test land's log shows OnLeave before OnJoin, and the new player's state isn't deleted. The player slot stays: the old generation's `playerLeft` reaches the membership queue behind the parked join, and the drop rule keeps the new entry's slot. Repeat with the OnLeave resolver failing and with it timing out at the deadline: the leave is dropped (`onLeaveDropped`), and the join still applies after it.
13. **Tokens that don't fit.** An old token after a reattach (already consumed), a token for another land instance, and a token with a different player ID. Expected: each falls back to a fresh join.
14. **A disconnect during a reattach's join-pending phase.** Hold the reattach before its flip, and disconnect the new session. Expected: the reattach fails cleanly, and the entry is detached again with a fresh grace (or leaves, past the D4 limit), with no slot or token left behind.
15. **The timer only enqueues.** Hold at `.inputDrain`, let the grace timer fire. Expected: the keeper's state is unchanged (the entry is still detached, still a member) until the drain's turn applies the expiry input.
16. **A stale leave notification.** Hold the adapter's handling of `playerLeft` (an adapter hold point), complete a fresh join of the same player ID meanwhile, then release. Expected: the notification names an older generation and is dropped; the new entry's slot stays.
17. **The sole player's expiry and the empty-land timer.** A detached sole player on a land with a short `destroyWhenEmptyAfter`, OnLeave's resolvers held past it, then released. Expected: the land isn't destroyed while the leave is pending; one `.leave` is recorded; then the empty timer arms and the land is destroyed. With a drain started while the leave is pending instead: OnLeave is dropped and counted, and a parked join fails with `landShuttingDown`.

## 9. Public API and wire

Everything new, all additive and source-compatible. Line numbers in this section are from `exp/next` at 6a251cea (#360).

**Approval.** The maintainer's D5 (a) requires the token, so it needs these fields. Main approved the encoding below as additive on 2026-11-09: trailing optional indexes and an optional key, compatible in both directions, and sent only when a land sets `reconnectGrace` (default `nil`), so no measured path changes its bytes. The wire freeze is main's measurement version; this lands on `exp/next` and ships after the rerun's data commits.

**Public API (Swift).**
- `LandConfig.reconnectGrace: Duration?`, default `nil` (off): a new stored property with a defaulted init parameter (D1).
- `TransportJoinPayload.reconnectToken: String?` and `TransportJoinResponsePayload.reconnectToken: String?`, each with a defaulted init parameter.
- The close code in `onDisconnect`: a new `TransportDelegate` requirement `onDisconnect(sessionID:clientID:closeCode:)`, with a protocol-extension default that calls today's `onDisconnect(sessionID:clientID:)`. So a delegate that implements only the old one still works, and sees no code. The NIO transport calls the new one. `nil` means no code reported.

**Wire, per encoding.** The token is a string, sent only when the land has a grace (in the join response) or the client holds one (in the join).
- **`json` (keyed objects):** a new optional key `reconnectToken` in the `join` and `joinResponse` payloads. Swift's `Codable` decoders and the SDK ignore unknown keys, and an absent key decodes as nil.
- **`opcodeJsonArray` (positional, `TransportMessageEncoder.swift:161-180`, `TransportMessageDecoder.swift:53-108`):**
  - joinResponse: `[105, requestID, success, landType?, landInstanceId?, playerSlot?, encoding?, reason?, stateUpdateFeatures?, reconnectToken?]`, a new trailing **index 9**;
  - join: `[104, requestID, landType, landInstanceId?, playerID?, deviceID?, metadata?, reconnectToken?]`, a new trailing **index 7**.
  - The encoder already writes optionals positionally up to the last present one, padding earlier absent ones with null, so nothing shifts: every existing index keeps its meaning.
- **`messagepack`:** the same arrays (`MessagePackTransportMessageEncoder.swift`, `MessagePackDirectDecoder.swift:137-150`), plus the map form (`decodeTransportJoinResponsePayload`, `:377-390`), which gets the `reconnectToken` key.
- **The SDK** (`sdk/ts/src/core/protocol.ts`): `buildMessageArray` and `decodeJoinResponseArray` (`:979-987`) and the join's array get the same index, and the object forms the same key. Codegen isn't affected: these are transport payloads, not schema types.

**Compatibility, both directions.** Every decoder of these arrays reads its optionals as `array.count > N ? … : nil` (the Swift opcode and MessagePack decoders) or by index (`payload[8]` in the SDK), and checks only a minimum length (`array.count >= 3`). So:
- an old client against a new server ignores index 9 of the join response, or the key, and never sends a token: its rejoin is a fresh join (newest wins), as today;
- a new client against an old server: the old server ignores index 7 of the join, or the key, and sends no token, so the client has none to present and joins fresh.

Neither direction shifts a position, so this is additive. Anything that would move an existing index isn't, and goes to the maintainer.

**The check.** #360's generic round-trip (`MessagePackTransportMessageRoundTripTests`: every payload, every field set, through every encoding) must cover the new field, and fails on a form that drops it. The code PR also adds old-shape and new-shape cases to each decoder's tests, for both directions above.

## 10. Decisions

The maintainer chose each recommended option on 2026-11-09 (D1-D5, then D6). The options are kept as the record of what was weighed.

**D1. The grace's length, and where it's set.**
- (a) A process env var (`RECONNECT_GRACE_MS`) for every land.
- (b) Per land in the definition (`LandConfig.reconnectGrace: Duration?`, default `nil` = off).
- (c) Per land, with an env override.

**Decided: (b).** The grace is game semantics. A lobby and a match want different ones, and a land that deletes players in OnLeave must opt in knowingly. A suggested value for GameDemo is 30 s.

**D2. Which disconnects enter the grace.**
- (a) Every disconnect.
- (b) Every one except a 4012 and a deliberate client close (1000), which needs the close code through `onDisconnect`.
- (c) Only ones the server didn't start.

**Decided: (b).**
- 4008, 4010 and 4011 are the cases a reattach with a firstSync fixes.
- 4012 would likely fail again.
- A client that closes with 1000 means to leave.

Until the close code reaches the adapter, treat every disconnect the server didn't start as entering the grace.

**Settled (Review's first pass, then Main, 2026-11-09).** As first written, the interim rule contradicted (b): a client that closes with 1000 would keep its player for the full grace. v1 includes the close-code plumbing (§ 6, § 9), so the interim rule covers only a transport outside this repository that reports no close code, which is consistent with (b). The paragraph stays as the record. If v1 shipped without the plumbing, the interim rule would be a deviation from (b) and need the maintainer's OK.

**D3. When OnLeave runs, and what other players see during the grace.**
- (a) OnLeave at the grace's end only. Others see the player as it was, idle, and nothing is recorded until the expiry.
- (b) OnLeave at the disconnect, with a new OnReconnect to restore the player. That restores nothing GameDemo deleted, so the problem stays.
- (c) As (a), plus optional `OnDisconnect` and `OnReconnect` handlers. They are recorded lifecycle inputs, so a land can mark the player away, for example a `connected` flag others see, deterministically in replay.

**Decided: (a) for v1, with (c) as an opt-in follow-up.**
- (a) needs no record format change.
- A connection query in `LandContext` is not an option: it isn't a recorded input, so a handler reading it would break replay.

**D4. The limit on reconnects.**
- (a) No limit within each grace.
- (b) Each detach starts a fresh grace, but at most N reattaches per player in a window (for example 5 in 60 s). Past that, a disconnect leaves at once.
- (c) One grace budget per player that a reattach doesn't refill.

**Decided: (b).** It bounds the 4010 reattach loop (§ 6) and a flapping client without punishing one network switch. Also: the token is single-use, and a detached player counts toward `maxPlayers`.

**D5. Proof on a land without authentication.**
- (a) The token is required.
- (b) The player ID alone suffices.

**Decided: (a).** With (b), any client that knows a player ID takes over its state. With (a), a join without the token is today's newest-wins join, with no new hijack surface.

On a land with authentication, the JWT identity alone could suffice. Decided: the token is required there too, so one rule covers every land. The JWT subject must also match.

**D6. Who owns the grace (Review's design item).**

- (A) **The adapter's timer, as revision 2 wrote § 5-8.**
  - The keeper holds the detached entry and offers a leave by entry generation. The adapter owns the timer and a `GenerationTable` ticket for its own per-player state (the slot, the token), and drives the expiry through the membership queue into the keeper.
  - Two owners, with a cross-layer ticket between them.
- (B) **The keeper owns the detached state and the expiry,** as its own timed turn, like the empty-land timer it already owns (`scheduleDestroyIfNeeded`, `LandKeeper.swift:4584`).
  - The adapter reacts to the resulting leave as it does to a leave today: it releases the slot and drops the token, through a new keeper-to-transport notification (`LandKeeperTransport`), checked against the entry generation it names.
  - One owner and no cross-layer ticket. The expiry is a keeper turn that a keeper hold point can stop, and it's the natural place for D3 (c)'s later recorded OnDisconnect and OnReconnect.

What changes under (B):
- § 5 is unchanged, apart from the empty-land timer's interplay, which moves into one actor.
- § 6 is unchanged: the leave and its IDs are the same.
- In § 7, the adapter's grace ticket and the expiry through the membership queue go away. The expiry still has to be ordered against a reattach, a join and a disconnect, so the keeper's expiry turn checks the entry generation and the `detached` mark in one segment, and a reattach that is in its membership-queue admission must be told apart (test 12).
- In § 8, the hold moves to a keeper hold point (`.graceExpiry` in `LandKeeperHoldPoint`), and test 6 checks that the keeper cancels its timer at destroy.

**Decided: (B)** (the maintainer, 2026-11-09). It keeps all of a player's lifecycle in the keeper, which owns the entry, the generation and the empty-land timer already, and it leaves the adapter with reactions only. It costs one new transport notification. § 5-8 are written for (B), with the maintainer's phase-separated-turn rule (§ 7).

**D7. One leave shape or two: open, for the maintainer (Review's design item).** § 7 gives the expiry a request → result-turn leave, while today's client-initiated leave still awaits OnLeave's resolvers inline (`LandKeeper.swift:2306-2340`).
- (a) The code PR builds the request/result leave once and moves the normal leave onto it too. That's one of the paths CLAUDE.md lists as not yet in turns, and the parked-join rule then covers normal leaves as well.
- (b) Two leave paths in v1, with an issue filed at merge to converge them.

**Recommended: (a),** as long as the PR stays reviewable: one leave shape to hold-test. Otherwise (b), with the issue.

## 11. Out of scope

- Buffering `.player` events during the grace.
- An explicit leave message.
- Moving the join and the client-initiated leave into keeper turns. That's the reentrancy target, and it stays separate; the grace's own paths (detach, expiry, reattach) are turns from the start (§ 7).
- A grace for replay viewers.

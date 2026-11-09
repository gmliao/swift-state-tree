# Disconnect grace: keep a disconnected player so a reconnect keeps its state

Status: open (#334). The design note, with the maintainer's choices settled (§ 9, D1–D5 as recommended, 2026-11-09). It is not reviewed yet, and there is no code; implementation waits for a build slot.

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
- The keeper already tolerates an entry without a client: `InternalPlayerSession.clientID` is optional (`:4772-4795`), and `isFirst = playerSession.clientID == nil` gates OnJoin (`:1588`, `:1604`). The detached state can build on this.

## 3. Proposed model

A player entry gets a third state between member and gone: **detached**.

- **attached → detached.** A disconnect that enters the grace (§ 9, D2) detaches the entry. This happens in a keeper turn: no OnLeave, and no player-state change by the framework. The entry keeps its player-state data (device ID, metadata, services), its player slot, and its place in `maxPlayers`.
- **detached → attached.** A rejoin within the grace that presents valid proof (§ 4) reattaches the entry. OnJoin doesn't run, a new entry generation is taken, and the client gets a firstSync.
- **detached → gone.** At the grace's end, the normal leave runs: OnLeave, the recorded `.leave` input, the slot release and the empty-land timer.

The grace is off by default, so a land that doesn't opt in behaves exactly as today.

## 4. What a reconnect presents

- **A server-issued reconnect token.**
  - It's in the join response: a new optional `reconnectToken` field in `TransportJoinResponsePayload` (`TransportMessage.swift:174`), sent only when the land has a grace.
  - It's 128 random bits. The server stores it on the entry, bound to (land ID, player ID, entry generation).
  - It's single-use: it's consumed when the reattach is admitted. A reattach issues a new token.
  - The client sends it back in a new optional `reconnectToken` field of `TransportJoinPayload` (`:146`), together with the land instance ID and the player ID.
- **Identity.** The player ID the join resolves to (`preparePlayerSession`) must equal the detached entry's.
  - On a land that authenticates, that already means the same JWT subject.
  - On a land that doesn't, the player ID is a free claim, so the token is what proves it (§ 9, D5).
- **No valid proof.** The join is handled as today: newest wins. If the player ID names a detached entry, that entry leaves (OnLeave), and a new member joins (OnJoin). So the grace adds no hijack path that the free player-ID claim doesn't already give.
- **CanJoin.** It runs on a reattach, as it does on today's reconnection (`isReconnection`, `:1550`, skips only the `maxPlayers` check). A land can then refuse a banned player's reattach.

## 5. The player during the grace

- **State.** It is untouched. The framework doesn't write game state. Ticks keep running, and handlers see nothing new, because `LandContext` has no connection list. Whatever OnJoin added stays.
- **Actions and client events.** There are none: there's no session. At the detach, the jobs of the entry generation are cancelled, as at a leave today (`cancelActionJobs`). Their responses couldn't reach the client anyway, since the action-response tickets end at the disconnect. After a reattach, the client resends what it needs.
- **Server events.**
  - `.session(old)` targets are dropped, as today.
  - `.player(id)` events emitted during the grace are dropped, not buffered: the firstSync at the reattach carries the state, and events are transient. Buffering would need a bound and a replay rule, which v1 skips.
- **Sync.** At the detach, the player's sync cache and firstSync mark are cleared, as today. That's what makes the reattach's sync a firstSync (the snapshot path `syncStateForNewPlayer` already uses). `.perPlayer` fields are part of the state and come back in that snapshot.
- **The empty-land timer.** `scheduleDestroyIfNeeded` (`:4584-4585`) checks `players.isEmpty`. A detached entry keeps the land alive until its grace ends; the empty timer then starts as usual. Worst case: a land outlives its last connection by the grace plus `destroyWhenEmptyAfter`.
- **A drain or shutdown during the grace.** A detached entry is dropped without OnLeave, as a connected player is at a drain today. Its grace timer must not act afterwards (§ 7).

## 6. Sync lag, closes, replay and recording

**Which closes enter the grace (§ 9, D2).**
- The adapter starts 4008, 4010, 4011 and 4012 itself (`transport.closeSession(_, with:)`, `Transport.swift:63-73`). So it can note a pending close reason per session before `onDisconnect` arrives.
- A disconnect the server didn't start (TCP loss, pong timeout, a client close) arrives with no reason. Telling a deliberate client close (1000) from a dropped one (1006) needs the close code passed through `onDisconnect`. That's a protocol change, with a default overload for existing transports.

**Sync lag (#344).**
- `syncLag` is per session and removed at the disconnect (`TransportAdapter.swift:1332`), so a reattach starts fresh tracking with a firstSync. That's what a 4010 or 4011 client needs.
- The slow-consumer window counts resyncs per session, though. A client that is simply too slow would loop: 4010, then a reattach, then 4010 again. Only the reattach limit (§ 9, D4) bounds that loop.
- 4012 means the server can't encode this player's view, and a reattach's firstSync would most likely fail the same way. So a 4012 should leave at once.

**Recording and replay.**
- The detach and the reattach are not recorded inputs in the recommended option, D3 (a). Replay then sees what the inputs say:
  - the player's OnJoin;
  - its actions, with the session and client IDs recorded on each input, so the new IDs after a reattach are just values;
  - one `.leave`, at the grace's end.
- The recorded leave's `resolvedAtTick` is the tick at the expiry, not at the disconnect. A disconnect's timing is wall-clock today too, so determinism doesn't change. The reevaluation docs need one line: the leave is recorded when the grace ends.
- If OnDisconnect and OnReconnect hooks are chosen (D3 (c)), they become new recorded lifecycle kinds (a record format minor bump, 3.x), and replay must apply them like `.join` and `.leave`.
- Replay viewers (`mode == .reevaluation`) never get a grace: they run no OnJoin and no OnLeave (`:2291-2295`).

## 7. Reentrancy

This follows CLAUDE.md § Reentrancy and `Notes/plans/2026-11-05-reentrancy-helpers.md`.

- **The detach and the reattach are synchronous keeper turns.** Each re-reads `players[playerID]` and acts only when its ticket matches:
  - the detach's ticket is the session's entry generation;
  - the reattach's ticket is the token's entry generation.
- **The grace timer is a callback that can outlive its instance.**
  - It captures the player ID and the detached entry's generation, plus a `GenerationTable` ticket for the adapter's per-player state (the slot, the token map).
  - At expiry, it goes through the membership queue (so it is ordered against joins and disconnects) into a keeper call that removes the entry only `ifCurrent`: same generation, still detached.
  - It never removes by player ID alone. A reattach takes a new generation in the same segment as its admission, so a late expiry finds a newer entry and does nothing.
- **The keeper needs a leave by entry generation.** Today's leave matches by client ID and session ID (`:2266-2277`), but an expired entry has neither.
- **Adapter state is kept during the grace: the player slot and the token.**
  - Released at the grace's end, under the same ticket, never by key from the timer.
  - `membershipCoordinator.releasePlayerSlot` (`TransportAdapter.swift:1379`) moves from the disconnect to the expiry for a detached player.
- **Newest wins during the detach (#92).**
  - A reattach is admitted through the same membership queue and admission as a join, so the join-pending phase (#224) and the in-turn flip (#69) apply unchanged.
  - Two reattaches with one token: the first consumes it, and the second falls back to a fresh join, which supersedes as today.
- **The expiry runs on the membership queue,** so it can wait behind a slow CanJoin, OnJoin or OnLeave resolver, up to the resolver deadline. The grace may then end later than set, but never earlier.
- **Entering the grace releases nothing the keeper later needs.** The OnLeave resolvers move to the expiry, which stays on today's "re-check by hand" path until leave moves into turns.

## 8. Tests (holds, not timing)

Every gate and hold key comes from `KeyedGates.freshKey()` or `fresh` (#358). The grace timer's fire is a hold point (for example `.graceExpiry`), so no test sleeps for the grace.

1. **Expiry racing a reattach, reattach first.** Hold the expiry between the timer's fire and its keeper segment, reattach, then release. Expected: no OnLeave, the entry is attached with a new generation, and the expiry is a no-op.
2. **The same race, expiry first.** Hold the reattach at `admitJoinEntry`, let the expiry run, then release. Expected: the token is invalid, and the join falls back to a fresh join with OnLeave, then OnJoin. The join response says it wasn't a reattach.
3. **An action job in its resolvers at the detach.** Hold at `.actionComplete`, disconnect, then release. Expected: the job is rejected, not delivered; its slot is read; no cap slot leaks.
4. **A reattach in the join-pending phase (#224) and the in-turn flip (#69).** Hold the reattach before its flip, and send frames. Expected: they are deferred and applied in order after the flip, as for a join.
5. **Two reattaches with one token.** Hold the first at admission. Expected: the second becomes a fresh join and supersedes the first.
6. **A drain during the grace.** Hold the expiry, call `shutdownAllLands()`, then release. Expected: the land is released, the timer does nothing, and `transportCallsAfterDestruction == 0`.
7. **Close kinds.** A 4012 leaves at once. A 4010 or 4011 detaches, and a reattach gets a firstSync. A deliberate client close leaves at once, if D2 says so.
8. **The reattach limit (D4).** Past the limit, a disconnect leaves at once.
9. **The empty land.** With only detached players, there's no destroy until the grace ends. After it, the empty timer runs.
10. **Replay.** Record a detach, a reattach, actions and an expiry. Expected: the replay verifies with 0 mismatches, and exactly one `.leave` is recorded, at the expiry.
11. **The default.** With the grace off, the existing leave and join tests pass unchanged.

## 9. Decisions

The maintainer chose each recommended option on 2026-11-09. The options are kept as the record of what was weighed.

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

## 10. Out of scope

- Buffering `.player` events during the grace.
- An explicit leave message.
- Moving join and leave into keeper turns. That's the reentrancy target, and it stays separate.
- A grace for replay viewers.

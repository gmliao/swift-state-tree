# Router join: one session ticket, one join attempt at a time (#99, #97)

Status: open (rev 5: rev 4 rebased on 4c, merged as #224 at 2e6f2e6; see § Rev 5. Reviews of rev 1 at b770108 and rev 2 at 53dc204 addressed). Part of PR d1 in [the reentrancy plan](2026-11-05-reentrancy-helpers.md#join-and-session-pr-d1); this note fixes the details for one PR.

## Rev 5: what 4c changed (main at 2e6f2e6)

Read the rest of this plan through these points. Where they differ, rev 5 wins.

**The join path today.**
- `handleJoinRequest` checks connected (`sessionToClient`) and not bound (`sessionToBoundLandID`), then awaits the land lookup or creation, binds `sessionToBoundLandID`, then awaits `preparePlayerSession` and `admitJoin`.
- **`admitJoin` returns after the admission, not after the flip.** On the in-turn path the router then sets `.joinPending(JoinPending)` and waits for the flip in a router-owned Task (`awaitFlip`). On the off path `admitJoin` returns after the whole join, and the router sends the JoinResponse and sets `.joined` inline. So § "One source of truth" no longer needs the bind before `performJoin` "because `performJoin` returns only after the flip": that reason is gone. The bind stays before `admitJoin` so that a disconnect during the admission is forwarded to the adapter.
- **The phase is `.awaitingJoin`, `.joinPending(JoinPending)` or `.joined`.** `JoinPending` holds an attempt number (`lastJoinAttempt`), the land ID, the request ID and the adapter. `awaitFlip` writes only in segments that first check `isPending(sessionID, attempt:)`. `.joinPending` is set only after the admission, so nothing marks a join in progress across the land lookup and `admitJoin`.
- **`onDisconnect`** removes the router's maps (the phase included) in one segment and, when bound, forwards the disconnect to the adapter in an unawaited Task.
- **`SessionID` reuse is rejected at the transport** while the old session is held (connected, being disconnected through the delegate's cleanup, or server-closed and not yet confirmed). Rev 4's reading holds.

**What is still open.**
- **#97 on both paths:** nothing re-checks the session after `admitJoin` returns. The in-turn path sets `.joinPending` for a session that disconnected during the admission (re-adding a phase entry its `onDisconnect` removed) and starts `awaitFlip`. If the disconnect's cleanup already removed the join's waiter, `awaitJoined` finds none and returns as if the join had flipped, so `awaitFlip`, finding itself pending, sets `.joined` for the gone session. If the waiter was failed first, it fails `.disconnected` and leaves the entry at `.awaitingJoin`. Either way a phase entry outlives its connection. The off path sends a JoinResponse to the gone session and sets `.joined`. The adapter side is already clean (its disconnect is ordered after the admission by the membership queue, and 4c's `.disconnected` failure covers the flip wait), so what leaks is router state, plus a response to a closed session. A disconnect during the land lookup leaves the binding, which the in-turn path never removes.
- **#99:** a second join during the land lookup or the admission passes both checks. On NIO the inbound chain serializes a session's frames, so this needs a transport without the chain. A server close doesn't send a join.
- **The failure paths** (`denied`, the `catch`) remove the binding by `SessionID` alone, without checking that the attempt is still theirs.

**Changes to the design.**
- **One phase, set before the first await.** `.joinPending` becomes `.joining(JoinAttempt)`, set in the segment of the checks. `JoinAttempt` is the attempt number, plus, once chosen, the land ID and adapter, plus, once admitted, the request ID the flip wait needs. A second join while `.joining` gets `JOIN_IN_PROGRESS`.
- **The ticket is the attempt number, not a `GenerationTable<SessionID>`.** `onDisconnect` removes the phase, so `isCurrent(sessionID, attempt:)` (today's `isPending`) fails for an attempt whose session ended. With no `SessionID` reuse, a session's phase entry belongs to its connection, so a per-session generation would add nothing the attempt doesn't give. This is the one deviation from the reentrancy rule's `GenerationTable` helper; the check is the same `ifCurrent` shape, written over the phase. **To confirm in the next check.**
- **Every segment after an await re-checks the attempt:** after the land lookup (bind and record the adapter), after `preparePlayerSession`, and after `admitJoin` (in-turn: start `awaitFlip`; off path: send the JoinResponse and set `.joined`). A stale attempt writes no router state and sends nothing. The adapter cleanup belongs to the disconnect forwarded by `onDisconnect`, which is idempotent and ordered after the admission.
- **The generation-keyed adapter cleanup is dropped.** Under the contract the keyed `onDisconnect` can't reach a newer connection's state, and the forwarded disconnect already cleans up. That settles rev 4's open point.
- **The forward in `onDisconnect`** stays a Task (unchanged). The disconnect only has to reach the adapter after the admission it may race, and the membership queue orders that.

**Tests, revised.**
- Hold points on the router: `afterLand`, `beforeAdmit` and `afterAdmit` (beside 4c's `flipWaitResumed`).
- 1 and 2 as written, with the first join held at `afterLand`. They need a second join to reach the router while the first is suspended, so they drive `LandRouter.onMessage` directly (the transport's chain doesn't serialize router calls made directly).
- 3 as written.
- 4 is split by path. **In-turn:** held at `afterAdmit`, then a disconnect, then release: no phase entry is left, no `awaitFlip` writes, and the adapter is clean. **Off path:** the same hold. No JoinResponse is written to the gone session, no phase entry or binding is left, and the keeper's player is removed.
- 5 is 4c's `disconnectWhilePending` and isn't repeated.
- 6 as written.
- 7 becomes a new-ID reconnect: a join held at `afterAdmit`, a disconnect, then a reconnect with a new `SessionID` and a join. The new join gets its own response, and the old join, released, writes nothing of either session. The reused-ID case is 4c's rejection tests.
- The legacy adapter sweep (A1) is unchanged.

## Rev 4: one `SessionID` per connection

The maintainer decided that a `SessionID` is not reused (4c, [its plan](2026-11-06-join-pending-inbound.md) § The contract). `WebSocketTransport.handleConnection` rejects an ID it still holds, and callers pass a fresh ID per connection. For this plan:
- **The reused-ID cases become rejection cases.** Test 7 and its variant no longer reconnect under the same `SessionID`. They check that the reconnect is rejected while the old session is held, that a reconnect with a new ID gets its own response, and that the old join, when released, touches nothing of the new session.
- **The generation-keyed cleanup** ("A stale ticket after `performJoin`") is kept as a defensive check, not as the guard against reuse. It may shrink to the keyed `onDisconnect` once 4c lands; that's settled in this plan's next check.
- **"Reconnect with a reused `SessionID`" and "a new ticket under a reused ID"** in § No stranded client read as "a new connection, with a new `SessionID`".

## What is left

On NIO, #112's `InboundTaskChain` already runs one session's connect, messages and disconnect one after another, and each finishes before the next starts. Two joins from one client no longer overlap there. Two paths are still open:

- A server-initiated close: `WebSocketTransport.closeSession` calls `handleDisconnection` directly, outside the session's chain, so `LandRouter.onDisconnect` can run while that session's join is suspended.
- A transport without a per-session chain.

Both reach the same function, `LandRouter.handleJoinRequest`:

- It checks "connected" (`sessionToClient`) and "not bound" (`sessionToBoundLandID`), then awaits `getLand`/`getOrCreateLand`, `preparePlayerSession` and `performJoin` before it binds or sets `.joined`.
- Its failure paths (`denied`, the inner `catch`, the outer `catch` in `onMessage`) remove the binding by `SessionID` alone.

Effects:
- A second join that starts during the first passes both checks (#99).
- A disconnect during the awaits leaves a binding that is never removed, and a keeper player with no session (#97, the ghost join).

## Change

### One ticket per session

`LandRouter` gets `sessions: GenerationTable<SessionID>`. `onConnect` issues the session's ticket, and `onDisconnect` ends it, both in the same segment as the existing map writes.

### One source of truth for "join in progress": the handshake phase

The router's `sessionHandshakePhase` becomes `.awaitingJoin`, `.joining(JoinAttempt)` or `.joined`. It's 4c's `.joinPending`, extended: there is no separate attempt map.

`JoinAttempt` holds:
- the session ticket;
- once the land is chosen, its adapter.

`handleJoinRequest` checks connected and `.awaitingJoin`, then sets `.joining(attempt)`, all before its first await.
- A second join while `.joining` is answered with its own code, `JOIN_IN_PROGRESS`. Clients can tell it from `JOIN_ALREADY_JOINED`.
- After the land lookup or creation, inside `sessions.ifCurrent(ticket)`, one segment records the attempt's adapter, binds `sessionToBoundLandID`, and enters 4c's message handling for a joining session (negotiated encoding, forwarded to the adapter). This happens **before** the `performJoin` await, because on the in-turn path `performJoin` returns only after the flip.
- After `performJoin`, inside `ifCurrent`, the phase becomes `.joined`.

### A disconnect during the join

Once the attempt has an adapter, `onDisconnect` forwards the disconnect to it **at once**, as today when bound:
- The adapter's `onDisconnect` is idempotent per generation.
- Its membership queue orders it after the admission.
- An in-turn waiter fails promptly with `.disconnected`, not after the 10 s timeout.
- Before the adapter is chosen, there is nothing in any adapter to clean up.

Either way, `onDisconnect` ends the ticket and removes the phase in the same segment.

### A stale ticket after `performJoin` (the session disconnected during it), on every outcome

**Success, throw (`JoinFlipError`, `JoinError`, any error) or denied:** the join runs the adapter's cleanup itself.
- **The cleanup is keyed by the join's connection generation**, not by `SessionID` alone: it's the `connectionGeneration` the join passed to `performJoin`, which the adapter records for the session.
  - The adapter cleans up only if the session's recorded generation still matches.
  - With a reused `SessionID`, a newer session already admitted to that adapter has a newer generation, and is left alone (CLAUDE.md: never remove keyed state by key alone from a callback that can outlive its instance).
  - This is a generation-checked variant of `onDisconnect(sessionID:clientID:)`.
- It's idempotent, so a disconnect already forwarded makes it a no-op. It covers the case where the forward came before the admission was queued.
- Only the router's own map writes and the join response are suppressed (the client is gone).
- So the membership, the slot, the joining record and the keeper's player never leak.

**Before `performJoin`** (stale after the land lookup): no bind, and no response.
- A land created only for the doomed join is still created (the creation is the await the disconnect came during).
- It has no players, so its destroy-when-empty timer removes it.

### Failure paths with a current ticket

They remove the binding and the phase only if they are still their own (a ticket compare), never by key alone. The `.timeout`, `.onJoinFailed` and `eventOverflow` cleanup (adapter `onDisconnect`, then `closeSession`) is unchanged.

### Legacy adapter path

`TransportAdapter` join (sweep A1): the "already joined" check moves into the membership queue's admission segment.

### No stranded client

Every join gets a join response, or its session gets a close. A join ends without sending its response only when its session's ticket has ended. That happens only in `onDisconnect`, and the client has then seen, or is seeing, the close.
- A later connection is a new session: a new `SessionID` on NIO, or a new ticket under a reused ID. Its phase starts at `.awaitingJoin`, so it never gets `JOIN_IN_PROGRESS` from a doomed attempt.
- The doomed join, when it resumes, writes no router state: its ticket isn't current. It can't remove the newer join's phase or binding.
- `JOIN_IN_PROGRESS` therefore only answers a second join while the first join's session is alive, and that first join sends its own response.
- An await that never resumes is #104 (deadlines), and this PR doesn't change it.

## Not in this PR

- #98: Code-2's.
- #113: the NIO chain's bound, its own PR.
- #104: deadlines.
- R3: lookup by `LandID`, PR d2.
- `performJoin` taking the ticket into its admission segment (d1 in the reentrancy plan) only if the held test below needs it; otherwise it's a follow-up.

## Tests (hold points on the router: `afterLand`, `beforeJoin`, `afterJoin`)

1. **Second join:** a join held at `afterLand`, then a second join for the same session. The second is answered `JOIN_IN_PROGRESS`. Release the first: one keeper join, and the binding is the first's.
2. **First join fails:** as test 1, but the first fails after the release. It removes only its own phase and binding, and a later join succeeds.
3. **#97, disconnect before the adapter is chosen:** a join held at `afterLand`, then `onDisconnect`, then release.
   - No binding, no keeper player, no join response.
   - A land the join created exists with no players, and is destroyed by its timer (a short test destroy delay).
4. **#97, disconnect during `performJoin`**, for both outcomes:
   - (a) it succeeds (held at `afterJoin`): the keeper's player is removed, and the leave comes after the join;
   - (b) it throws (OnJoin fails, and the flip times out with a short test timeout): no membership, slot, joining record or keeper player is left.
5. **Disconnect during an in-turn flip:** the join is admitted, and the session disconnects before its flip. The join ends promptly with `.disconnected` (the waiter fails at the forwarded disconnect), not with `.timeout`, and the adapter's state is clean.
6. **Server close during the join**, through `WebSocketTransport.closeSession` with a stub connection: as in test 3.
7. **Reconnect with a reused `SessionID`:** a join held at `afterLand`, then a disconnect, then a reconnect with the same `SessionID` (a new ticket) and a join. The new join gets its own response, not `JOIN_IN_PROGRESS`. Release the old join: it touches nothing, and the new binding survives.
   - **Variant:** the old join is held at `afterJoin` (admitted to the same adapter), then the disconnect, reconnect and new join (admitted too), then the old join is released. Its generation-checked cleanup leaves the new session's membership, slot and keeper player in place. This checks to fail with the cleanup keyed by `SessionID` alone.

Each test must fail when its guard is removed (mutation check).

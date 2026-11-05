# Router join: one session ticket, one join attempt at a time (#99, #97)

Status: open (rev 3: reviews of rev 1 at b770108 and rev 2 at 53dc204 addressed; lands after 4c, whose `.joinPending` phase it builds on). Part of PR d1 in [the reentrancy plan](2026-11-05-reentrancy-helpers.md#join-and-session-pr-d1); this note fixes the details for one PR.

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

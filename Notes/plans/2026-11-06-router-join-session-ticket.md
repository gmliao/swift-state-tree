# Router join: one session ticket, one join attempt at a time (#99, #97)

Status: open. Part of PR d1 in [the reentrancy plan](2026-11-05-reentrancy-helpers.md#join-and-session-pr-d1); this note fixes the details for one PR.

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

**One ticket per session.** `LandRouter` gets `sessions: GenerationTable<SessionID>`.
- `onConnect` issues the ticket and `onDisconnect` ends it, both in the same segment as the existing map writes.

**One attempt per session.** `joinAttempts: [SessionID: Ticket<SessionID>]` holds the in-progress attempt.
- `handleJoinRequest` checks connected, not bound and no attempt, then records its attempt, all before its first await.
- A second join while one is in progress is answered with `joinAlreadyJoined` ("join in progress").

**After each await**, the join continues only inside `sessions.ifCurrent(ticket)`:
- The bind (`sessionToBoundLandID`), `.joined` and the attempt's removal happen in those segments.
- If the ticket is no longer current, the session disconnected: no bind and no join response.
  - If the disconnect came after `performJoin` admitted the player, the join itself sends the adapter's `onDisconnect`. The router's `onDisconnect` doesn't, because it sees an attempt in progress instead of a binding. So the leave always comes after the join that admitted the player.
  - A land the join created is left to its destroy-when-empty timer.

**Failure paths** remove the binding and the attempt only if they are still their own (a ticket compare), never by key alone.

**No stranded client.** Every join gets a join response, or its session gets a close. An attempt becomes doomed (it ends without sending its response) only when its session's ticket has ended. That happens only in `onDisconnect`, and the client has then seen, or is seeing, the close.
- `onDisconnect` also removes the session's attempt entry, in the same segment as `sessions.end`. So the entry never outlives its session.
- A later connection is a new session: a new `SessionID` on NIO, or a new ticket under a reused ID. Its join sees no attempt and goes ahead. It never gets "join in progress" from a doomed attempt.
- The doomed join, when it resumes, sees its ticket is not current and touches nothing. It can't remove the newer attempt or binding either: the attempt entry stores the ticket, and the removal compares it.
- "Join in progress" therefore only answers a second join while the first attempt's session is alive, and that first attempt sends its own response.
- The one case still open is an attempt that never resumes at all (an await that hangs). Then the first join never gets a response. That's #104 (deadlines), and this PR doesn't change it.

Test 6: a join held at `afterLand`, then a disconnect, then (with a reused `SessionID` and a new ticket) a reconnect and a join. The new join gets its own response, not "join in progress". Release the old join: it touches nothing, and the new binding survives.

**Legacy adapter path** (`TransportAdapter` join, sweep A1): the "already joined" check moves into the membership queue's admission segment.

## Not in this PR

- #98: Code-2's.
- #113: the chain's bound; it follows this PR.
- #104: deadlines.
- R3: lookup by `LandID`, PR d2.
- `performJoin` taking the ticket into its admission segment (d1 in the reentrancy plan) only if the held test below needs it; otherwise it's a follow-up.

## Tests (hold points on the router: `afterLand`, `beforeJoin`, `afterJoin`)

1. A join held at `afterLand`, then a second join for the same session: the second is answered "join in progress". Release the first: one keeper join, and the binding is the first's.
2. The same, but the first fails after the release: it removes only its own attempt, and a later join succeeds.
3. #97, disconnect before the bind: a join held at `afterLand`, then `onDisconnect`, then release. No binding, no keeper player, no join response.
4. #97, disconnect after admission: a join held at `afterJoin` (the player is admitted), then `onDisconnect`, then release. The keeper's player is removed, and that leave comes after the join.
5. A server close during the join, through `WebSocketTransport.closeSession` with a stub connection: as in 3.

Each test must fail when its guard is removed (mutation check).

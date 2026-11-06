# Join PR 4c: a pending-join phase, a bounded inbound deferral, and the join E2E (#69)

Status: rev 3.1, agreed (on the maintainer's contract that a `SessionID` is not reused; rev 2's check X1–X3 and decision D, and rev 3's R1–R4, addressed). Implementation next; four points from the last check (I1–I4: the handler's rejected flag kept chain-local, one close path through `closeSession`, NIO's handoff guarantee, the send stream's element type) are settled in the PR. PR 4c of [Join as a turn input](2026-11-05-join-as-turn-input.md) (§5 "Router handshake", tests 13 and 18). 4a merged as #194, 4b as #212. [Router join ticket (#99, #97)](2026-11-06-router-join-session-ticket.md) builds on the phase this adds. #113 (the NIO chain's own bound) stays a separate PR. Fixes #216.

**In-turn path only.** The off path (`IN_TURN_SYNC=false`) keeps awaiting the whole join inline.

## Today (after #212)

On the in-turn path, `LandRouter.handleJoinRequest` awaits `performJoin`, which returns only after the join's flip, up to `JOIN_FLIP_TIMEOUT` (10 s). On NIO, #112's `InboundTaskChain` runs a session's frames one after another, so while the join waits:
- **Every later frame of that session waits in the NIO chain**, unbounded (that queue is #113's), not in the adapter.
- **Its disconnect waits too.** A client that closes during a slow flip isn't seen until the join ends, so the join times out (10 s) instead of failing `.disconnected` at once. Its keeper player and slot stay for that long.

The router comment at the `performJoin` call states this, and names "a pending-join phase that defers those frames" as the way out.

## The contract: one `SessionID` per connection (decision D, option 2)

A `SessionID` names one connection, and is never used for another. Every per-session map in the transport, the router and the adapter is keyed by `SessionID`. Under this contract a late act keyed by an ended session's ID finds nothing, or finds that session's own leftover state, and never a newer connection's. So keyed cleanup is safe by contract, and no owner token is threaded through the queues and waiters.

**Enforced at the one entry, `WebSocketTransport.handleConnection`:**
- **It rejects a `SessionID` it still holds:** one in `sessionQueues` (connected), or in `serverClosedSessions` (closed by the server, its disconnect not yet confirmed).
- **A rejected connection** is closed at once (`connection.close()`). It gets no queue and no client ID, `onConnect` isn't called, and it's counted (`connectionsRejectedSessionIDInUse`) and logged at warning level with the ID.
- **The result is returned:** `handleConnection` becomes `@discardableResult ... -> ConnectionAcceptance` (`.accepted` or `.rejected(.sessionIDInUse)`), so existing callers compile unchanged and a caller can see the rejection. The rejection is named in the docs.
- **Every caller's duty (R1): a rejected connection never calls `handleIncomingMessage` or `handleDisconnection`.** Both are keyed by `SessionID`, so a rejected connection calling either would act on the session it shares the ID with: its disconnect would remove that session's queue, client ID and player mapping, and its frames would arrive as that session's. The duty is stated on `handleConnection`.
  - **The NIO handler consumes the acceptance** (`WebSocketSessionHandler`). On `.rejected`, it marks itself rejected. It forwards no inbound frame (frames already queued on its chain are dropped when they run), and its `handlerRemoved` skips `handleDisconnection`. The transport has already closed the connection.
- **Held means any of these** (R2), each bounded by the session's own lifetime:
  - in `sessionQueues` (connected);
  - in `closingSessions`, a new set: `handleDisconnection` inserts S at its start and removes it after the delegate's `onDisconnect` returns. This covers the window in which the queue is already gone but the router and adapter are still cleaning up;
  - in `serverClosedSessions` (closed by the server, its disconnect not yet confirmed), which exists today and is bounded by the close-confirm timeout (`expireUnconfirmedServerClose`).
- **"Fully gone"** means none of these: the transport has finished `handleDisconnection` for it, including the delegate's cleanup. There are no tombstones after that, since an unbounded set of ended IDs would grow with every connection.
- **The precondition is what closes #216; the check is a best-effort catch.** Callers pass a fresh `SessionID` per connection. The NIO server does, with a new `UUID` per connection (`WebSocketSessionHandler`). The check catches a reuse only while the ID is held. A reuse after the session is fully gone isn't detected, but there is nothing of the old session left for it to collide with, apart from async work that outlives the cleanup (a flip wait, a drain, a keeper await). Under the precondition that work can't meet a newer connection. Without the precondition it could, and the docs say so.

**#216 is closed by the precondition.** The keyed `handleDisconnection(sessionID:)` tears down only its own connection when IDs aren't reused. The check (with `closingSessions`) rejects the reuse #216 describes while the old ID is held, which covers its window at the transport. 4c closes #216 with that explanation and tests 7 and 8.

**#217's reuse handling** (ending a previous queue when its ID is reused) isn't needed: a held ID is rejected before any queue is replaced. 4c owns that path, and its rejection test covers it.

**The connection generation stays as a defensive stamp only,** on the reply and error frames listed below. `sendSessionFrames` already drops a frame whose generation isn't the session's current one. There's no generation-checked cleanup API, and no owner token.

## Change

### 1. The adapter splits admission from the flip wait

`performJoin` is today `enqueueMembership { performJoinQueued }`, then `awaitJoined` when the join completes in a turn.
- **New `admitJoin(...)`** returns after the admission (the queued part), with the `JoinResult`.
- **`awaitJoined(sessionID:)`** (exists) waits for the flip or the failure.
- **`performJoin` stays** as `admitJoin` + `awaitJoined`, for direct callers and the legacy path.

### 2. The router returns after the admission: `.joinPending`

`HandshakePhase` gains `.joinPending(JoinPending)`, holding the land ID, the request ID and the adapter. #99/#97 renames it `.joining(JoinAttempt)`, adds its `GenerationTable` ticket, and sets it before the land lookup; the shape is the same.
- **`handleJoinRequest`** binds the session (as today), awaits `admitJoin`, then sets `.joinPending`.
  - If the join completes in a turn, it **starts the flip wait in a router-owned Task**, then returns. The session's chain moves on.
  - Otherwise (the off path, or a direct-path join), nothing changes: the response and initial sync are sent inline, then `.joined`.
- **The flip wait's Task** awaits `adapter.awaitJoined`. In the segment after it returns, it checks that the session is still `.joinPending` with this attempt (it compares the attempt, which also guards against a second join's phase under #99/#97), and acts:
  - **Success:** the phase becomes `.joined`.
  - **Failure:** in that segment, it removes the binding and the phase. Then it sends the join error, stamped with the session's generation. For `.timeout`, `.onJoinFailed`, `.eventOverflow` and `.inboundOverflow`, it then calls the adapter's `onDisconnect`, then `transport.closeSession`. Under the contract these act on this session or on nothing, and both are idempotent for an ended session.
  - **No longer pending** (the session disconnected): no router write and no response. The forwarded disconnect already cleaned the adapter up.

### 3. Frames of a `.joinPending` session

- They're decoded with the negotiated encoding, as for `.joined` (MessagePack included), and forwarded to the bound land's adapter.
- A second join is answered `JOIN_ALREADY_JOINED`, as today (the session is bound). #99/#97 gives it `JOIN_IN_PROGRESS`.
- **A disconnect** is forwarded to the bound adapter at once, as today when bound. **The boundary is when the adapter's `onDisconnect` runs** (R3), in its membership queue: that's where the waiter fails `.disconnected`, the joining record and its deferred frames go, and the ticket ends. The router seeing the disconnect first doesn't end anything in the adapter. The waiter fails as soon as the adapter's disconnect runs, not at the timeout.

### 4. The adapter's inbound: one ingress, one queue per session

**Serial delivery is a precondition** (S1). A session's inbound frames are delivered one at a time: a frame's `onMessage` returns before the next is delivered. NIO's `InboundTaskChain` (#112) does this, and `WebSocketTransport` is the only production transport. So no frame of a session can reach the router between its bind and its admission: the join frame's handler is still running then. A frame the client sends right after the join reaches the adapter after the admission, and finds the joining record. **No reservation is needed** (rev 2's `deferPendingJoinFrame` is dropped), so rev 2's X2 (an overflow while reserved, with no join to fail) has no phase to occur in. The precondition is stated on `TransportDelegate.onMessage` and in the docs. A transport that delivers concurrently would need rev 2's reservation, with X2's terminal failure; that's out of scope until one exists.

**Ingress** (`_onMessageImpl`) only decides where a frame goes:
- **Joining** (an in-turn join record that hasn't failed): append to `JoiningSession.deferredInbound`, with its byte count.
- **Joining, failed** (the record stays until the disconnect): drop, counted. This is the record's terminal state, and nothing re-adopts it.
- **Draining** (`inboundAfterFlip[S]` exists, §5): append to it.
- **Otherwise:** dispatch inline, as today.

**The bound** is 256 frames and 256 KiB per session, from `JOIN_DEFERRED_INBOUND_MAX` / `JOIN_DEFERRED_INBOUND_MAX_BYTES` (EnvHelpers, `TransportEnvKeys`, `JoinFlipConfig`). It covers the joining and the draining queue together. The count and the bytes are checked and tested separately.
- **Before the flip,** over the bound: the join fails with a new `JoinFlipError.inboundOverflow`. The router answers `JOIN_INBOUND_OVERFLOW`, then cleans up and closes the session, as in §2.
- **After the flip,** over the bound (S2): the frame isn't dropped silently. The adapter sends `INBOUND_OVERFLOW` (stamped), then ends the session through its `onDisconnect` and `transport.closeSession`, like the writer's over-ceiling rule: the client lost an action it sent, so it must reconnect. Counted (`inboundOverflowClosures`).
- **Dropped frames are counted** (`inboundDroppedForJoiningSessions`) wherever the queue goes: a failed join, a disconnect, a supersede. These are the same sites as 4b's held events.

### 5. After the flip: the drain (B3, S3)

- **When:** the commit that flips the session moves its `deferredInbound` into `inboundAfterFlip[S]`, with the session's ticket (`sessionTickets`). This happens **after `enqueueFrames` has taken the whole flip element** (JoinResponse, firstSync, the held events of 4b). If the queue isn't empty, it starts **one drain Task** for S. The drain never runs inline in the commit.
- **The drain loop:**
  1. In one segment: check the ticket with `ifCurrent`. If current, pop the first frame. If not (the session ended or was superseded), drop the rest, counted, and remove the entry.
  2. Await the **private dispatch** (`dispatchInbound`), which decodes and routes like the inline path. It never goes through ingress, so it can't re-append the frame.
  3. In the segment after the dispatch returns: if the queue is empty, remove the entry, synchronously, in that segment. Otherwise loop.
- **The entry stays while a dispatch is awaited.** It is the active-drain marker, so a frame that arrives during the dispatch is appended behind the remaining ones (§4), never dispatched inline ahead of them.
- **Replies:** the action responses and errors a drained frame causes are stamped with the generation captured with the queue (the defensive stamp). A drained action whose keeper await outlives its session's disconnect has its reply dropped by `endedSessions` or, failing that, by the stamp.
- **Back-pressure:** for S, the chain's `onMessage` returns once the frame is appended, until the drain ends. The bound above limits the queue.

### 6. Final frame, then close (R4)

The join errors that close the session (`JOIN_INBOUND_OVERFLOW`, `INBOUND_OVERFLOW`, and #212's `JOIN_EVENT_OVERFLOW`, also `.timeout` and `.onJoinFailed`) are sent and closed **in order**. Today the close can overtake the error: `closeSession` finishes the session's send queue and cancels its drain, so a frame still in the queue, or still in the adapter's writer, is never written.
- **New `TransportAdapter.sendFinalFrameAndClose(_:to:)`:** one writer element holding the frame, then a close marker. The writer takes elements in order, so the frame reaches the transport first.
- **New `WebSocketTransport.closeSessionAfterQueuedFrames(_:timeout:)`:** it yields a close marker into the session's send stream, behind the frames already queued. When the drain task reaches the marker, it closes the connection, then runs the session's disconnect as `closeSession` does today. A frame queued after the marker is dropped.
- **The wait is bounded** by `finalFrameCloseTimeout` (default 1 s, `TransportEnvKeys`). A timer Task falls back to `closeSession` if the marker hasn't been reached, for example because the client stopped reading. Either way the close happens once.
- **The router's join-failure path** (§2) and the adapter's after-flip overflow (§4) use it, instead of a send and then a `closeSession`. A transport without the marker (`supportsCloseSession` false) keeps today's best effort, and the docs say so.
- **Size:** about 80 lines across the writer element, the transport's stream element type, and the drain. If it grows past that in the implementation, the fallback is best effort in the docs, and I'll report it before going on.

### 7. Off path and legacy

Unchanged. The router awaits `performJoin` inline, which completes the join there. The legacy adapter join doesn't defer.

## What the reentrancy rule asks, and where

- **Keeper state:** no change. The deferral and the drain are adapter (outside-turn) state, and a drained frame reaches the keeper as an ordinary input.
- **Outside turns:**
  - the router's flip wait checks its phase and attempt in the same segment as its writes;
  - the drain checks `sessionTickets` with `ifCurrent` when it pops a frame, and removes its entry only in the segment that sees the queue empty.
  - Keyed acts on a session after an await are safe by the contract (one `SessionID` per connection), which `handleConnection` enforces for every held ID.
- **Order-sensitive per-session work** goes through one queue per session (`deferredInbound`, then `inboundAfterFlip`), with one ingress and one dispatcher.

## Docs

- `docs/transport/README.md` (EN and zh-TW):
  - § Join and Session Flow: frames sent before the JoinResponse are applied after OnJoin, in order, up to the bound. Over it, the join fails with `JOIN_INBOUND_OVERFLOW` before the flip, or the session is closed with `INBOUND_OVERFLOW` after it.
  - § Connections: one `SessionID` per connection, and serial delivery per session, stated as preconditions. `handleConnection`'s rejection while an ID is held, and the caller's duty after one.
  - The closing join errors arrive before the close, within `finalFrameCloseTimeout`.
- FAQ: both codes, and the rejection.
- AGENTS.md: the env keys.

## Tests (holds, no timing)

1. **Frames during the join:** an action and a client event are sent while the join is admitted but not flipped. They're applied after OnJoin, in order. Both MessagePack and json.
2. **A frame right after the JoinResponse,** while the router is still `.joinPending` (the flip wait held before it sets `.joined`): decoded with the negotiated MessagePack, and applied after the deferred ones.
3. **Order across the flip (B3):** frames deferred before the flip, and one sent while the drain's first dispatch is held. The one sent during the drain is applied last, and none is applied twice. Mutation: remove the entry before the dispatch (or dispatch through ingress), and it fails.
4. **The bound before the flip:** separate cases for the count (257 frames) and the bytes (one frame over 256 KiB). The join fails with `inboundOverflow`, the session is closed, the keeper's player is removed, and the drops are counted. **What the connection wrote** (a recording connection) ends with the `JOIN_INBOUND_OVERFLOW` error, followed by the close. Also: a frame after the failure (its record kept until the disconnect) is dropped and counted, not adopted.
5. **The bound after the flip (S2):** the drain held, then frames past the count, and separately past the bytes. The connection's last written frame is `INBOUND_OVERFLOW`, followed by the close, and `inboundOverflowClosures` is 1. No frame is dropped silently.
6. **Disconnect while `.joinPending`:** the adapter's disconnect is held, then released (R3). On release, the join ends with `.disconnected` (with a long test flip timeout), not `.timeout`. The deferred frames are dropped and counted. No router write after it, and no join response.
7. **A held `SessionID` is rejected, through the real lifecycle (R1):** session A is connected, and B connects with A's ID through an `EmbeddedChannel` with the real `WebSocketSessionHandler`. `handleConnection` returns `.rejected(.sessionIDInUse)`, and B's connection is closed. B then sends a frame and runs its whole lifecycle (close, `handlerRemoved`, its chain drained). Afterwards A's queue, client ID and player mapping are intact, A still receives frames, the delegate saw no `onConnect`, `onMessage` or `onDisconnect` from B, and the counter is 1. The same with A's ID in `serverClosedSessions`, and in `closingSessions` (its `handleDisconnection` held in the delegate). An ID that is fully gone is accepted. Mutations: remove the check, or have the handler ignore the acceptance; each fails.
8. **#216's window at the transport (R2):** A's `handleDisconnection` held **before it removes the queue**, then B connects with A's ID and is rejected. On release, A's cleanup removes only A, and nothing of B was created. A second hold, inside the delegate's `onDisconnect` (the queue already gone, `closingSessions` holding the ID), gives the same result. Mutation: remove `closingSessions`, and the second case accepts B.
9. **Serial delivery:** a frame sent right after the join frame on the NIO chain reaches the adapter after the admission, is deferred, and is applied after the flip. Mutation: dispatch it inline, and it's applied before OnJoin.
10. **The full order at the flip (S3):** an OnJoin that sends a targeted event, and a deferred action that emits an event. The joiner receives JoinResponse, firstSync, OnJoin's event, and then the action's event, in that order. Mutation: drain inline in the commit, and it fails.
11. **Disconnect during the drain:** the drain held after its first dispatch, then a disconnect, with the adapter's disconnect held, then released (R3). After the release, the rest is dropped and counted, and nothing more reaches the keeper for that session.
12. **A reply after the session ended:** a drained action held in the keeper, then a disconnect. On release, no frame is written for it, and the drop is counted.
13. **Record and replay:** a recorded run with an action deferred during a join replays with 0 mismatches. The action is recorded at the turn it was applied in, after OnJoin.
14. **Off path and legacy:** with `IN_TURN_SYNC=false`, the router still awaits inline (the existing tests), no `.joinPending` is set, and no frame is deferred.
15. **Final frame, then close (R4):** `JOIN_EVENT_OVERFLOW` (#212), `JOIN_INBOUND_OVERFLOW` and `INBOUND_OVERFLOW`, each with frames already queued ahead of it. The recording connection shows the queued frames, then the error, then the close. A client that stops reading (the connection's send held): the close comes at `finalFrameCloseTimeout`, once. Mutation: a send and then `closeSession`, and the error is missing from what was written.

Mutation checks:
- the deferral removed (frames processed while joining): 1 fails;
- the drain order: 3 fails;
- each bound removed: 4 and 5 fail;
- the router awaiting inline again: 6 fails (it ends in `.timeout`);
- the held-ID check removed, or the handler ignoring the acceptance: 7 fails;
- `closingSessions` removed: 8 fails;
- a send and then `closeSession`: 15 fails;
- the drain run inline: 10 fails.

## E2E (test 18 of the join plan, S4)

New CLI steps (`Tools/CLI`, direct to main, before the PR uses them):
- `reconnectClient { index }`: close a client's connection, then join again as the same player on a new connection (a new `SessionID`).
- `addClient { samePlayerAs: index }`: join a second connection as an existing client's player.
- **After a replacement:**
  - the step asserts that the old socket was closed (its close event, within the step's timeout);
  - the old client is dropped from the convergence set;
  - the next `assertConverged` must be **conclusive**: it retries within a bounded count and fails if the result is still inconclusive.

Scenarios in `Tools/CLI/scenarios/game/`, under messagepack, on both CI matrix legs (in-turn on and off), each with a gating `assertConverged`:
- the existing late joiner after monsters spawned;
- a reconnect;
- two clients with one playerID: the old connection is closed, and the new one converges.

## Not in this PR

- #113: the NIO chain's bound.
- #99/#97: the session ticket, `JOIN_IN_PROGRESS`, and the land-lookup window. Its reuse tests become rejection tests (noted in its rev 4).
- #104: deadlines.

## Changes in rev 3.1 (from rev 3's check)

| Item | Answered in |
|---|---|
| R1: the rejected connection's own disconnect tears down the held session | The contract: the caller's duty; the NIO handler consumes the acceptance. Test 7 runs the real lifecycle |
| R2: #216 is closed by the precondition, not by the check | The contract: "held" includes the new `closingSessions`, "fully gone" is defined, and the rest is best effort. Test 8 holds before the queue's removal and inside the delegate |
| R3: the disconnect boundary | §3: the adapter's `onDisconnect`. Tests 6 and 11 hold and release it |
| R4: the error before the close | §6: final frame, then close, with a bounded wait, also for #212's `JOIN_EVENT_OVERFLOW`. Tests 4, 5 and 15 assert what the connection wrote |

## Changes in rev 3 (from rev 2's check and decision D)

| Item | Answered in |
|---|---|
| D: `SessionID` reuse | The contract: option 2, enforced in `handleConnection` (connected or server-closed IDs; no tombstones; a documented precondition for the rest), test 7 |
| X1: no owner identity across the queues and the waiter | The contract: keyed acts are safe by it, so no owner token is needed. The generation stays as a defensive reply stamp |
| X2: an overflow while reserved | §4: the reservation is dropped under serial delivery. A failed join's record is terminal and refuses frames (test 4) |
| X3, #216 | The contract: fixed by the rejection, test 8. Rev 2's generation-checked overloads are dropped |
| S1: the reservation | §4: not needed under serial delivery (the only transport), stated as a precondition, test 9 |
| #217's reuse handling | The contract: not needed. A held ID is rejected before any queue is replaced |

## Changes in rev 2 (from rev 1's check)

| Item | Answered in |
|---|---|
| B1: the failure path's awaits act by `SessionID` alone | rev 3: safe under the contract |
| B2: a drained action answers on a reused session | rev 3: no reuse. Replies keep a defensive stamp, test 12 |
| B3: the drain order and re-append | §4 (one ingress), §5 (private dispatch; the entry as the drain marker), test 3 |
| S2: a silent drop after the flip | §4 (`INBOUND_OVERFLOW` and a close), test 5, with the count and bytes separate |
| S3: the drain after the whole flip element, from a Task | §5, test 10 |
| S4: the E2E after a replacement | E2E |
| Replay with a deferred input | test 13 |

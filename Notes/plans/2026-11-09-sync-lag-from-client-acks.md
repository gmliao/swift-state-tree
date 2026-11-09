# Sync lag from client acks: design note (2026-11-09)

Step 5 of [the core round](2026-11-09-core-round-and-full-rerun.md), issue #332. This note is for Review before any code. The maintainer's decisions are fixed. This note covers how they map onto the code.

Decisions, restated:
- every sync frame carries a sync sequence;
- the client acks the latest applied sequence about once a second;
- lag over 3 s **while acks still arrive** closes the session with a new "resync" code, and the client rejoins and gets a firstSync;
- a third resync within 60 s is a slow-consumer close, with no auto-rejoin;
- no ack for 10 s is an unresponsive close;
- every threshold is configurable;
- a resync has rejoin semantics;
- the ack is never a turn input and is never recorded;
- `SendBacklogBound` and the pong timeout stay.

Solutions consulted:
- [callback outlives its instance, clears by key](../solutions/2026-11-05-callback-outlives-its-instance-clears-by-key.md);
- [cause recorded at a later callback](../solutions/2026-11-07-cause-recorded-at-a-later-callback.md);
- [same-session frames overtake each other](../solutions/2026-11-04-same-session-frames-overtake-each-other.md);
- [unbounded queues and awaits at boundaries](../solutions/2026-11-06-unbounded-queues-and-awaits-at-boundaries.md).

## What the code has today

These facts shape the design:

- **There is no wire version** (deferred to #246). Compatibility is negotiated at join through `stateUpdateFeatures`:
  - the client declares what it decodes;
  - the router refuses a join that lacks a required feature with `joinStateUpdateFeatureMissing` (`LandRouter.swift` ~510);
  - `pathIndex` and `fieldMerge` already work this way (`TransportEncodingConfig.stateUpdateFeatures`).
- **One merged broadcast frame is encoded once**, and the same bytes go to every recipient (`TransportAdapter.planMergedBroadcastFrame`). A per-recipient field can't go inside those bytes without encoding once per recipient.
- **A session with nothing to send gets no frame.** A `.noChange` update is skipped per recipient.
- **4008 (`SendBacklogBound`) is the only application close code.**
  - The pong timeout closes with 1001.
  - Every other server-requested close is 1000: `Transport.closeSession(_:)` has no code parameter.
- **The TS SDK never reconnects.** Every close destroys the views (`runtime.ts` `onclose`). The only reconnect path is ws-loadtest's (`--reconnect on-server-close`).

## 1. The sequence: one counter per land, in every state-update frame

**The counter.** The sequence is a **per-land sync counter**, `syncSeq: UInt64`. It doesn't count per session.
- The adapter takes the next value when it plans a sync cycle (`SyncPhasePlan`).
- Every state-update frame planned in that cycle carries it: the merged broadcast frame, per-player frames, broadcast-only frames and the firstSync of a joiner.
- A cycle that doesn't commit leaves a gap. Gaps are allowed, and the sequence only has to increase.

**Why per land instead of per session.** A per-land value is the same for every recipient of a cycle, so the shared broadcast bytes stay shared. A per-session lag still comes out of it, because the server keeps each session's own unacked frames (§ 3). The acked value is compared against that session's own frames, never against frames other sessions received.

**Where the field goes in each encoding.** The format applies only when the session declared the feature (below).

| Encoding | Frame today | With `syncSequence` |
|---|---|---|
| `jsonObject` | `{"type":…, "patches":[…]}` | `{"type":…, "seq":N, "patches":[…]}` |
| `opcodeJsonArray` | `[opcode, patch…]` | `[opcode, N, patch…]` |
| `opcodeMessagePack` | `[opcode, patch…]`, or 107 `[107, stateArr, events]` | `[opcode, N, patch…]`, with `stateArr` in the same form inside 107 |
| MessagePack direct (`MessagePackDirectEncoder`) | map with `"type"` | the map gains `"seq"` |

An old decoder rejects a scalar at index 1 (`protocol.ts` ~490, `StateUpdateDecoder.swift` ~135). That is why the format change can't be silent.

**The "wire-version bump" is a new required state-update feature, `syncSequence`.**
- When lag tracking is on for a land (the default), the land's frames carry the sequence, and `syncSequence` joins the required features for every encoding, `jsonObject` included.
- An older client gets a clear join error instead of a misread frame.
- With tracking off, frames keep today's format and nothing is required. That gives one switch for tests and for embedders on old clients, the same pattern as `AtomicValueEncoding.keyed`.
- This needs no general version mechanism. #246 stays open for that.

**What carries no sequence.** Frames that aren't state updates: action responses, events sent alone, and join responses. They don't count towards lag. A live key-scope reset (firstSync on a live connection) is a state update and carries one.

## 2. The ack message and its cadence

**The message.** A client→server sync ack, `[108, seq]`, in **every** message encoding: JSON text for `json` and `opcodeJsonArray`, a MessagePack array for `messagepack`. 107 is server-only.
- It isn't a `TransportMessage` or a `MessageKind` case. The transport parses it before any message decoding: exactly two elements, both non-negative integers, the sequence fitting `UInt64` (in MessagePack, `0x92 0x6c` and an unsigned integer). Anything else goes to the normal decoder.
- *(Revised at implementation, agreed in review: the JSON form was `{"kind":"syncAck",…}`.)*

**Where the server handles it.** In `TransportAdapter.dispatchInbound`, before `MessageRoutingTable` routes actions and events to the keeper. It never reaches `LandKeeper.handleActionEnvelope` or `handleClientEvent`, so the recorder never sees it.
- The router's post-join decode accepts 108.
- During the handshake 108 isn't accepted, just as today only a join is.
- An ack from a session that isn't current is dropped (its generation is checked, § 3).
- An ack while a session's inbound is deferred or queued (joining, flip drain) is handled at once, not queued. It touches only lag state.

**Cadence.** The client keeps `lastAppliedSeq`, set after the patch loop of every state update it applies (SDK `view.handleStateUpdate`, ws-loadtest `session.handleDecodedMessage`).
- It sends `syncAck(lastAppliedSeq)` every `ackIntervalMs` (default 1000), **even when the value hasn't changed**. That is how "acks still arrive" is told apart from "no ack".
- It also sends one at once after applying a firstSync.
- An idle land then costs one small message per client per second.
- A slow reader that stops reading its socket still sends acks with its old value, so its lag grows and it gets a resync rather than an unresponsive close.
- **Every ack refreshes `lastAckAt`**, one with an unchanged value included. That is what keeps a slow reader's acks fresh.
- **Hidden browser tabs throttle timers**, so the SDK also sends an ack from the apply path once an interval has passed since the last one. On a busy land, frames arrive, they are applied, and the apply path keeps the acks fresh.
- **The ack timeout applies only while the session has unacked frames** (the maintainer's decision, 2026-11-09). Its clock starts at the later of the last ack and the oldest unacked frame's commit. So on an idle land, with nothing to ack, a hidden tab whose timers are throttled isn't closed. The first frame after a long idle gets a full `ackTimeout` to be acked, not an instant 4011. Transport liveness on an idle land stays with the pong timeout, which the browser answers by itself, in a background tab too. An outage on an idle land falls to the pong timeout as well.
- **#113's read pause stops acks too.** When the server pauses reading a connection that floods it with inbound frames, its acks stay unread. Such a client reaches the ack timeout (4011), not a resync (4009).

## 3. Lag state: where it lives and how closes are decided

**Where it lives.** All lag state is in the land's `TransportAdapter`, the actor that plans and commits sync frames. It is outside keeper turns.

| State | Contents |
|---|---|
| per session (keyed by `SessionID`, guarded by the existing `sessionTickets` generation) | `unacked`: a FIFO of `(syncSeq, commitTime)`, one entry per frame committed to that session since its last ack; `lastAckAt`; `closing`; and the session's resync token (below) |
| per resync token (entries expire `slowConsumerWindow` after their last resync) | the resync times within `slowConsumerWindow` |

**When tracking starts.** A session gets lag state only when its firstSync **commits**, which means its join has flipped. Its firstSync is the FIFO's first entry, and `lastAckAt` starts at that commit. A joining session, a session in its flip drain, and a session whose close is already under way have no lag state, so no decision is ever made about them. An ack from a session with no lag state is dropped.

**Lag.**
- An ack for `seq` pops every FIFO entry with `syncSeq <= seq`, and sets `lastAckAt`. An ack that pops nothing (an unchanged value) still sets `lastAckAt`.
- `lag = 0` when the FIFO is empty.
- Otherwise `lag = now − ` the commit time of the FIFO's **first** entry: how long the oldest frame the client hasn't confirmed has been out.
- Measuring from the oldest *unacked* frame, not from the newest *acked* one, matters on a sparse or tickless land. If a frame comes 5 s after the last acked one, the client has had no chance to ack it yet. Measured from the acked frame, its lag would read 5 s and a healthy client would be resynced. Measured from the unacked frame, it reads the time since that frame went out.
- The time is the commit to the writer, which is the point: bytes the kernel holds count as unacked.
- **The FIFO's bound.** It holds at most the frames committed during `resyncAfter` plus one check interval. A longer lag either closes the session or marks it `resyncPending` (below), and no frame is planned for a pending session. At 10 Hz with the defaults that is about 33 entries per session.

**The check.** It is one synchronous pass over the sessions, with no `await`. It runs on a 250 ms adapter timer, which is a `safeTaskSleep` loop owned by the adapter's `Lifecycle`. The timer also covers tickless lands, which have no sync cycle to piggyback on.

| Condition (checked in this order) | Decision |
|---|---|
| the FIFO isn't empty and `now − max(lastAckAt, first entry's commit time) > ackTimeout` (10 s) | close with *unresponsive* |
| `lag > resyncAfter` (3 s) and `now − lastAckAt > ackFreshness` (2 s, two ack intervals) | mark `resyncPending`: no more frames are planned for the session, and the decision waits for fresh acks |
| `resyncPending` and the acks are fresh again | the resync (or slow-consumer) decision below, **whatever the lag** |
| `lag > resyncAfter` (3 s), and this would be the token's `slowConsumerCount`-th resync (3rd) within `slowConsumerWindow` (60 s) | close with *slow consumer* |
| `lag > resyncAfter` | close with *resync*, and record the time for the token |

**Resync only while acks still arrive** (plan df1108e9, step 5). A client whose acks have paused is not resynced, whatever its lag. A phone that loses signal for 5–10 s (an elevator) can't receive a 4009. The channel would close behind it after the grace, the client would see 1006 when the signal returned, and it wouldn't rejoin. So a short outage would kill a session that TCP was still holding. Instead:
- **Silent with the lag under `resyncAfter`:** nothing. Frames keep flowing, and a short gap recovers on its own.
- **Silent with the lag past `resyncAfter`:** the session is marked `resyncPending`, and the server stops planning frames for it. When the acks resume it is resynced, now over a live path, so the 4009 is delivered.
- **Silent past `ackTimeout`:** an unresponsive close, the maintainer's choice for outages that last.

**Why a pending session gets no frames and is resynced whatever its lag.**
- Frames planned during the silence would queue up to `ackTimeout` worth of data ahead of a later 4009. They could push it past the 5 s `closeFrameTimeout`, and the client would see 1006 after all.
- Once frames are withheld, the client's lag no longer means anything. An ack of the last frame it actually received would read as lag 0, although it has missed every withheld frame. Without the flag it would silently diverge.
- The flag also keeps the FIFO bound above.

A slow reader is unaffected: it keeps acking its old value, so its acks stay fresh while its lag grows (§ 2).

**The resync token, which counts resyncs across rejoins.** A player ID can't do this. On a land that authenticates players, a guest's player ID is its session ID (`createGuestSession`), and a guest join that names a `playerID` is refused as `.unauthenticated` (#209). So a rejoining guest can't carry its old identity.
- At its first resync, a session gets a random token, 128 bits in hex. The 4009 close reason carries it: `resync:<token>`, well inside the 123-byte close-reason limit.
- The client presents the token at rejoin, as `resyncToken` in the join metadata. The new session inherits the token and its resync times. The next resync reuses the token, so the count follows the chain of rejoins.
- A token that is unknown or expired is ignored, and the join goes ahead as a fresh one. The token grants nothing beyond the count: it isn't an identity, a credential or a reconnect key.
- A client that drops the token only resets its own count. It can't take over anything.

**Ticket handling.** This follows the CLAUDE.md reentrancy rule.
- In the synchronous pass, the adapter marks the session `closing` and captures its ticket (`sessionTickets.ticket`), together with the transport's connection generation for that session.
- **The leave happens at the decision.** The adapter's `closeSession` runs `handleDisconnection` before it asks the transport to close. So the player leaves the land at the decision, and nothing that arrives during the grace below reaches the keeper.
- From then on, in the same segment:
  - acks for the session are ignored;
  - no new sync frame is planned for it;
  - frames still queued for it in the adapter's writer are dropped.
- The decision is final once made. A late ack doesn't undo it.
- After the pass, the close goes out through the transport: `closeSession(id, code:, reason:, generation:)`. The transport acts only if the connection generation still matches, so a rejoined connection under the same player is never closed by a decision about its predecessor.
- When the close returns, any bookkeeping goes through `ifCurrent(ticket)`. That is the first production call site of `ifCurrent`.
- The token's resync times are written in the synchronous pass, never after an `await`.

**The close path needs a code.**
- `Transport.closeSession`, `WebSocketConnection.close`, `NIOWebSocketConnection.close` and `WebSocketSessionHandler.close` gain `code:` and `reason:`, with defaults that keep today's 1000.
- The handler records the cause when it decides, before writing the frame, following the "cause recorded at a later callback" lesson.

**The close handshake.** For *resync* the handler writes the close frame. Once that write completes, it waits up to `closeGrace` (2 s) for the client's close frame before closing the channel. `closeForBacklog` closes at once instead.
- Closing at once, with unread inbound data, makes the kernel send an RST.
- An RST can discard what is still unread in the client's receive buffer, the close frame included. The client would then see 1006 and wouldn't rejoin.
- At 3 s of lag the client has seconds of data to drain, not minutes, so the grace is enough.
- **During the grace the handler reads and discards inbound.** That overrides #113's read pause for this connection. Otherwise the client's close frame, or acks it sent before seeing 4009, would fill the server's receive buffer and bring the RST back.
- **The bound.** The 4009 frame queues behind whatever NIO and the kernel still hold for the connection. If it isn't written within NIO's `closeFrameTimeout` (5 s), the channel closes without it, and the client sees 1006. A close discards pending writes. That is a stated limit, not a case the design covers. It needs more than about 5 s of data still unsent at the decision, which a 3 s lag at the measured rates doesn't produce. The SDK treats that 1006 as a disconnect, as it does today, and doesn't guess that it was a resync.

**Hold-point tests.** New `TransportAdapterHoldPoint` cases at the close `await` and at the check timer. Every interleaving is forced with `HoldPoints` / `TestGate`, never with timing.

| Interleaving | Expected |
|---|---|
| An ack arrives between the decision and the close | The session still closes, and the ack is dropped. |
| The player rejoins (new session, same player) while the old session's close is held | The new connection stays open. The close carries the old generation, and the transport drops it. |
| A sync cycle commits while the close is held | No frame is planned for the closing session. |
| The session leaves or disconnects while the close is held | No double close, and no resync is recorded twice. |
| Two resync decisions in one token chain, across a held close and a rejoin | The count is exact, and the third one is the slow-consumer close. |
| An ack arrives before the session's firstSync commits (joining, or join pending, #224) | The ack is dropped, and no lag state is created by key. |
| A lag check runs while the session drains its flip, or while its leave is under way | No decision is made for it. |
| A sync cycle plans frames while the session is `resyncPending` | No frame is planned for it. |
| A fresh ack arrives while the check that marks `resyncPending` is held | The check's decision stands for that pass. The next check resyncs. |
| The session ends, and an ack for it arrives later (an old generation) | The ack is dropped, and no lag state is recreated by key. |

**Lag fixtures** (a controllable clock, no hold points needed):

| Case | Expected |
|---|---|
| Acks every 1 s with the old value, lag past 3 s (slow reader) | A resync at the first check past 3 s. |
| Silent 2.5 s with frames acked up to its start (lag under 3 s at resume) | No resync and no close. |
| Silent 5 s (elevator): the lag passes 3 s while silent | `resyncPending` at the first check past 3 s and no more frames planned. A resync at the first check after the acks resume, even if they ack everything received. |
| Silent 11 s | `resyncPending` from 3 s on, then an unresponsive close at 10 s. No resync before it. |
| Acks with an unchanged value every 1 s (slow reader) | `lastAckAt` stays fresh: a resync, never `resyncPending` or 4011. |
| An idle land, no acks for 30 s, the FIFO empty | No close. |
| An idle land for 30 s without acks, then one frame, acked 1 s later through the apply path | No close: the timeout runs from the frame's commit. |
| A busy land with the ack timer throttled (no timer acks) | Apply-path acks keep it fresh: no `resyncPending`, no close. |
| A sparse land: one frame 5 s after the last acked one, acked within 1 s | Lag measured from that frame, so no resync. |

## 4. Close codes

| Code | Name | Server cause (`SessionCloseCause`) | Client behavior |
|---|---|---|---|
| 4008 | backlog (existing) | `backlogBytes` / `backlogUnwritable` | unchanged: disconnect |
| 4009 | resync | `syncLagResync` | auto-rejoin, then firstSync |
| 4010 | slow consumer | `slowConsumer` | disconnect, no auto-rejoin |
| 4011 | unresponsive | `ackTimeout` | disconnect, no auto-rejoin |

**How they fit with 4008.** 4009–4011 come from the adapter's lag check, and 4008 from the handler's byte bound. Whichever fires first closes the session, and the handler's first recorded cause wins. With the defaults the lag check fires long before the bound, so 4008 remains the memory guard for a client whose acks are lying, or for a land with tracking off.

**The pong timeout (1001) stays as the transport keepalive.** With tracking on, the ack timeout (10 s) normally fires first for a silent peer.

The new causes go into the lifecycle log, the transport profile counters and the docs' cause table.

**Configuration.** `EnvKeys.Server`, plus a `SyncLagPolicy` on `NIOLandServerConfiguration`, which the adapter receives:
- `SYNC_LAG_TRACKING` (default on);
- `SYNC_LAG_RESYNC_MS` (3000);
- `SYNC_LAG_SLOW_CONSUMER_COUNT` (3);
- `SYNC_LAG_SLOW_CONSUMER_WINDOW_MS` (60000);
- `SYNC_ACK_TIMEOUT_MS` (10000);
- `SYNC_ACK_FRESHNESS_MS` (2000): acks older than this pause the resync and slow-consumer decisions;
- `SYNC_LAG_CLOSE_GRACE_MS` (2000).

The client's interval is an SDK or ws-loadtest option, not a server setting. The server reports its configured timeout in `joinResponse`, so a client can check that its interval is well below it.

## 5. Clients and docs

**TS SDK (`sdk/ts`).** The SDK has no reconnect, so this is new work, not a reuse of an existing path:
- Declare `syncSequence`.
- Decode `seq` in all encodings.
- Track `lastAppliedSeq` per view, and send acks on a runtime timer.
- **On 4009:**
  - reopen the socket and rejoin every view with its land ID and the `resyncToken` from the close reason;
  - name a `playerID` in the rejoin only when the original join was authenticated or named one itself, never a guest's server-assigned ID, which an authenticating land would refuse;
  - reset `lastAppliedSeq` for every new connection, and send no ack on it before its firstSync;
  - **clear** the view state before applying the firstSync, because a firstSync applies as patches today and doesn't reset;
  - leave out the events emitted during the gap;
  - surface it to the app: a new `onResync` callback, and `onDisconnect` gets the reason for 4010 and 4011.
- Tests: frame decoding with and without the feature, the ack cadence, rejoin on 4009, no rejoin on 4010 and 4011, and state cleared before the firstSync.
- Codegen: only if the generated composables expose the new callbacks.

**ws-loadtest.**
- The same decode and ack.
- 4009 always triggers the reconnect path, with or without `--reconnect`. 4010 and 4011 never do.
- Counters in the report (`CloseSummary` already has `byCode`): `resyncs`, `slowConsumerCloses`, `unresponsiveCloses`, plus `lastAppliedSeq` on close records.
- The two step-6 client fixes land in the step-6 change, not here.

**Other clients that join lands.** These must declare and ack too, or run against a server with tracking off: `Tools/CLI` (E2E), the Swift test clients that join, and the reevaluation monitor's client. A replay land gets the same tracking as a live land.

**Docs (English and zh-TW together).**
- `docs/transport/README.md`: the frame field, `syncAck`, the close-code and cause table, and the environment variables.
- `docs/sdk/README.md`: connection loss, reconnecting, and delivery semantics (a resync is a rejoin).
- `docs/core/sync.md`: first sync.

## Open points for Review

1. *(Resolved in review: the resync budget is keyed by a resync token, not a player ID; see § 3.)*
2. **The lag check runs every 250 ms.** A decision can therefore land up to 250 ms past the threshold. ws-loadtest's expectation in step 6 is "about 3 s", within that.
3. **One PR: the server, the SDK, ws-loadtest and the `Tools/CLI` E2E clients together.** Review agreed. The required feature means that a server merged ahead of its clients would refuse every client that hasn't been updated, and CI's E2E clients are among them.
4. **Does a player keep its identity across a resync?** *Decided by the maintainer on 2026-11-09: option (a).* A resync is a real `OnLeave` and `OnJoin`, the same as today's reconnect, because it is an abnormal state anyway. The token keys the resync budget, and it reclaims the player ID where that is allowed. Position and role aren't kept. Detached membership, (b), becomes a separate issue covering every kind of disconnect. The options as they were put:
   - In this design the leave happens at the decision, so the land runs `OnLeave`. GameDemo's `OnLeave` removes the player (`HeroDefenseLand`: `state.players.removeValue`).
   - An authenticated player rejoins under the same ID but as a new player in the land. A guest comes back with a new ID.
   - **(a) The token reclaims the player ID.** The token is single-use, expires within 30 s, and is bound to the land and the old player ID. A guest's rejoin that presents it may name that ID. This is cheap, but the player still went through `OnLeave` and `OnJoin`. What survives is only state the land keys by player ID outside what `OnLeave` removes. Position and role don't survive in GameDemo.
   - **(b) Detached membership.** At a resync decision the session's connection is closed, but the player stays a member, detached, for up to `rejoinGrace`. No `OnLeave` runs, and no lifecycle event is recorded. A rejoin that presents the token reattaches the player under the same ID, without `OnJoin`, and gets a firstSync. If the grace runs out, the leave runs then, as a normal leave. This keeps position and role. It is a larger change, roughly another half day to a day: the detached state in membership, newest-wins and join pending (#224) interplay, and the hold-point tests for an expiry racing a reattach.
   - **Security, for both.** The token is a bearer secret for that membership:
     - it is 128-bit random, single-use and short-lived;
     - it is sent only on the connection being resynced, and is never logged;
     - it is consumed only when a join succeeds.
     It proves no more than possession of that connection. On an authenticating land an authenticated player still needs a JWT whose player ID matches, because the token never overrides auth. For a guest the token is the only proof, which equals what the guest had before. Over plain `ws://` an on-path observer could take the token, but it could already inject into that connection.

# Sync lag from client acks: design note (2026-11-09)

Step 5 of [the core round](2026-11-09-core-round-and-full-rerun.md), issue #332. This note is for Review before any code. The maintainer's decisions are fixed. This note covers how they map onto the code.

Decisions, restated (revised 2026-11-09: the resync is in place, see open point 4):
- every sync frame carries a sync sequence;
- the client acks the latest applied sequence about once a second;
- lag over 3 s **while acks still arrive** resyncs the session **in place**: the server sends it a fresh full view on the live connection, and the client clears its state and applies it. The player stays a member, with no `OnLeave` or `OnJoin`;
- a third resync within 60 s is a slow-consumer close (4010), with no auto-rejoin;
- 10 s of stale acks while frames are unacked is an unresponsive close (4011);
- every threshold is configurable;
- the ack and the resync are never turn inputs; the only trace in a recording is the sync stream's seed marker;
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
- It also sends one at once after applying a firstSync or a resync snapshot.
- An idle land then costs one small message per client per second.
- A slow reader that stops reading its socket still sends acks with its old value, so its lag grows and it gets a resync rather than an unresponsive close.
- **Every ack refreshes `lastAckAt`**, one with an unchanged value included. That is what keeps a slow reader's acks fresh.
- **Hidden browser tabs throttle timers**, so the SDK also sends an ack from the apply path once an interval has passed since the last one. On a busy land, frames arrive, they are applied, and the apply path keeps the acks fresh.
- **The ack timeout applies only while the session has unacked frames** (the maintainer's decision, 2026-11-09). Its clock starts at the later of the last ack and the oldest unacked frame's commit. So on an idle land, with nothing to ack, a hidden tab whose timers are throttled isn't closed. The first frame after a long idle gets a full `ackTimeout` to be acked, not an instant 4011. Transport liveness on an idle land stays with the pong timeout, which the browser answers by itself, in a background tab too. An outage on an idle land falls to the pong timeout as well.
- **#113's read pause stops acks too.** When the server pauses reading a connection that floods it with inbound frames, its acks stay unread. Such a client reaches the ack timeout (4011), not a resync.

## 3. Lag state: where it lives and how decisions are made

**Where it lives.** All lag state is in the land's `TransportAdapter`, the actor that plans and commits sync frames. It is outside keeper turns.

| State | Contents |
|---|---|
| per session (keyed by `SessionID`, guarded by the existing `sessionTickets` generation) | `unacked`: a FIFO of `(syncSeq, commitTime, isFullView)`, one entry per frame committed to that session since its last ack; `lastAckAt`; `phase` (`live`, `resyncPending`, `awaitingSnapshot`, `closing`); `resyncTimes` within `slowConsumerWindow` |

The resync count lives on the session, because the session survives a resync. No token is needed.

**When tracking starts.** A session gets lag state only when its firstSync **commits**, which means its join has flipped. Its firstSync is the FIFO's first entry, a full view, and `lastAckAt` starts at that commit. A joining session, a session in its flip drain, and a session whose close is already under way have no lag state, so no decision is ever made about them. An ack from a session with no lag state is dropped. The lag state goes with the session: a leave, a disconnect or a newest-wins replacement removes it in the same segment, and nothing recreates it by key.

**Lag.**
- An ack for `seq` pops every FIFO entry with `syncSeq <= seq`, and sets `lastAckAt`. An ack that pops nothing (an unchanged value) still sets `lastAckAt`.
- `lag = 0` when the FIFO is empty.
- Otherwise `lag = now − ` the commit time of the FIFO's **first** entry: how long the oldest frame the client hasn't confirmed has been out.
- Measuring from the oldest *unacked* frame, not from the newest *acked* one, matters on a sparse or tickless land. If a frame comes 5 s after the last acked one, the client has had no chance to ack it yet. Measured from the acked frame, its lag would read 5 s and a healthy client would be resynced. Measured from the unacked frame, it reads the time since that frame went out.
- The time is the commit to the writer, which is the point: bytes the kernel holds count as unacked.
- **The FIFO's bound.** It holds at most the frames committed during `resyncAfter` plus one check interval, or during `ackTimeout` behind an unacked full view (below). A longer lag resyncs the session, marks it `resyncPending` or closes it, and no frame is planned for a session that isn't `live`. At 10 Hz with the defaults that is about 33 entries per session, and about 103 behind a full view.

**The check.** It is one synchronous pass over the sessions, with no `await`. It runs on a 250 ms adapter timer, which is a `safeTaskSleep` loop owned by the adapter's `Lifecycle`. The timer also covers tickless lands, which have no sync cycle to piggyback on.

| Condition (checked in this order) | Decision |
|---|---|
| the first entry is a full view, unacked for `ackTimeout` (10 s) since its commit, and the acks are fresh | close with *slow consumer*: the client can't take its own full view |
| the FIFO isn't empty and `now − max(lastAckAt, first entry's commit time) > ackTimeout` | close with *unresponsive* |
| the first entry is a full view | no decision: a full view is exempt from `resyncAfter` |
| `lag > resyncAfter` (3 s) and `now − lastAckAt > ackFreshness` (2 s, two ack intervals) | mark `resyncPending`: no more frames are planned for the session, its events are dropped, and the decision waits for fresh acks |
| `resyncPending` and the acks are fresh again, or `lag > resyncAfter` | a resync. If it would be the `slowConsumerCount`-th (3rd) within `slowConsumerWindow` (60 s), close with *slow consumer* instead |

**The full-view exemption.** A firstSync or a resync snapshot is the one frame that can't be made smaller. On a large land over a slow link it can take more than 3 s to arrive, and resyncing it would only send the same frame again. So while the FIFO's first entry is a full view, `resyncAfter` doesn't apply. The client has `ackTimeout` to ack it. Fresh acks without it mean the client is reading, but too slowly to take its view (4010). Stale acks mean it has stopped (4011).

**Resync only while acks still arrive** (plan df1108e9, step 5). A client whose acks have paused isn't resynced, whatever its lag, because a phone that has lost signal (an elevator) can't receive anything. Instead:
- **Silent with the lag under `resyncAfter`:** nothing. Frames keep flowing, and a short gap recovers on its own.
- **Silent with the lag past `resyncAfter`:** the session is marked `resyncPending`, and the server stops planning frames for it. When the acks resume it is resynced in place, over the now live path.
- **Silent past `ackTimeout`:** an unresponsive close, the maintainer's choice for outages that last.

**Why a pending session gets no frames and is resynced whatever its lag.**
- Frames planned during the silence would queue up to `ackTimeout` worth of data ahead of the snapshot, and the client would have to read all of it before the view it actually needs.
- Once frames are withheld, the client's lag no longer means anything. An ack of the last frame it actually received would read as lag 0, although it has missed every withheld frame. Without the flag it would silently diverge.
- The flag also keeps the FIFO bound above.

A slow reader is unaffected: it keeps acking its old value, so its acks stay fresh while its lag grows (§ 2), and it is resynced at the first check past `resyncAfter`. Its frames stop at that point, so at most about `resyncAfter` of backlog sits ahead of its snapshot.

**The in-place resync.** All of it is in the check's synchronous pass and the next full sync plan. No `await` sits between the decision and its state changes.
- **At the decision**, in the pass:
  - record the time in `resyncTimes`, and set `phase = awaitingSnapshot`;
  - clear the FIFO: the frames in it no longer count once the client gets a full view;
  - clear the player's firstSync mark and per-player cache in the sync engine, which makes the player an *unsynced recipient*. This is a new named method, `SyncEngine.resetViewForResync(_:)`, not `clearCacheForDisconnectedPlayer`, whose contract is a player with no session left;
  - **a player with several sessions** (a second device, or the newest-wins window): that reset is per player, so **every session of the player is resynced** as one decision. Each gets `awaitingSnapshot`, a cleared FIFO, dropped events and the snapshot, and each client fires `onResync`. The count goes only on the lagging session. A healthy second session gets one redundant snapshot, and drops its events between the decision and its snapshot's commit, about one cycle; both are acceptable; closing the lagging one instead would punish the player for a short stall;
  - on a land without periodic sync, start a follow-up sync, the same path a failed firstSync already uses.
- **The snapshot** is planned by the next full sync plan's existing unsynced-recipient path (`planFullViewUpdate`): the player's whole view as a diff from empty, from the turn's end state. That path already runs inside a normal full cycle for a member whose firstSync failed to encode. It needs no join and no flip.
  - It is encoded as a new update kind, **resync** (opcode `3` in the opcode encodings, `"type":"resync"` in `jsonObject` and MessagePack direct). The encoder treats it as a firstSync: it forces definitions and resets the per-player key scope. Only a `syncSequence` client ever receives it, so the opcode is safe.
  - The plan records a sync-stream *seed* for the player, as it does for every full view. A seed for a player seeded before is marked as a rejoin, and the verifier checks its view hash against the replayed state at that point. So replay stays consistent, and the record format doesn't change.
  - As with every firstSync outside a broadcast key-scope reset, it requests one (#90). The next merged broadcast frame goes to every client in the land typed `.firstSync`, with all definitions. A rejoin costs exactly this today, but a resync now fires on its own: one slow client can cost every client in the land a fat frame up to `slowConsumerCount` times a window.
  - **Resets coalesce per cycle.** The request is a flag on the plan (`needsBroadcastKeyReset`), so several resyncs in one plan request one reset. Their count and their bytes (the reset frame's size times its recipients) are counted on their own.
  - If the snapshot doesn't encode, the player stays unmarked and the next full plan tries again, as for a failed firstSync.
- **At the snapshot's commit:** the FIFO restarts with the snapshot as its first entry, a full view, and `phase = live`. Frames after it are planned as usual, as diffs from the new cache.
- **Events.** From `resyncPending` (or the decision) until the snapshot commits, events targeted at the session, and its share of broadcast event frames, are dropped and counted, the same as during a rejoin. Its merged broadcast frames aren't planned at all.
- **What the land sees:** nothing. No `OnLeave`, no `OnJoin`, no lifecycle input. Position, role and every other per-player state stay.

**Ticket handling for the terminal closes** (4010, 4011). This follows the CLAUDE.md reentrancy rule.
- In the synchronous pass, the adapter sets `phase = closing` and captures its ticket (`sessionTickets.ticket`), together with the transport's connection generation for that session.
- **The leave happens at the decision.** The adapter's `closeSession` runs `handleDisconnection` before it asks the transport to close. So the player leaves the land at the decision, and nothing that arrives during the grace below reaches the keeper.
- From then on, in the same segment:
  - acks for the session are ignored;
  - no new sync frame is planned for it;
  - frames still queued for it in the adapter's writer are dropped.
- The decision is final once made. A late ack doesn't undo it.
- After the pass, the close goes out through the transport: `closeSession(id, with: SessionClose(code:reason:), generation:)`. The transport acts only if the connection generation still matches, so a rejoined connection under the same player is never closed by a decision about its predecessor.
- When the close returns, any bookkeeping goes through `ifCurrent(ticket)`. That is the first production call site of `ifCurrent`.

**The close path needs a code.**
- `Transport.closeSession`, `WebSocketConnection.close`, `NIOWebSocketConnection.close` and `WebSocketSessionHandler.close` gain a code and a reason, with defaults that keep today's 1000.
- The handler records the cause when it decides, before writing the frame, following the "cause recorded at a later callback" lesson.

**The close handshake.** For 4010 and 4011 the handler writes the close frame. Once that write completes, it waits up to `closeGrace` (2 s) for the client's close frame before closing the channel. `closeForBacklog` closes at once instead.
- Closing at once, with unread inbound data, makes the kernel send an RST, which can discard the close frame in the client's receive buffer. The client would see 1006 instead of the reason.
- **During the grace the handler reads and discards inbound.** That overrides #113's read pause for this connection. Otherwise the client's close frame, or acks it sent before seeing the close, would fill the server's receive buffer and bring the RST back.
- **The bound.** The close frame queues behind whatever NIO and the kernel still hold for the connection. If it isn't written within NIO's `closeFrameTimeout` (5 s), the channel closes without it, and the client sees 1006. Both closes are terminal, so this only costs the client the reason. It is a stated limit.

**Hold-point tests.** New `TransportAdapterHoldPoint` cases at the close `await`, at the check timer, and at the sync cycle's `await` before its plan. Every interleaving is forced with `HoldPoints` / `TestGate`, never with timing.

| Interleaving | Expected |
|---|---|
| A resync is decided while a sync cycle is suspended before its plan | The plan reads the current phase: a full plan carries the snapshot, any other plan no frame for the session. |
| An ack arrives between the resync decision and the snapshot's commit | It refreshes `lastAckAt` and pops nothing. After the commit, only an ack at or past the snapshot's sequence pops it. |
| A targeted event is queued while the session is `resyncPending` or `awaitingSnapshot` | It is dropped and counted, never delivered after the snapshot. |
| A player with two sessions, one lagging, is resynced while a sync cycle is suspended before its plan | Both sessions get the snapshot from that plan, each fires `onResync` once, and only the lagging session's count grows. |
| The session leaves, disconnects or is replaced (newest-wins) while `awaitingSnapshot` | No snapshot is planned for it, and no lag state is recreated by key. The new session gets its own join firstSync. |
| A sync cycle plans frames while the session is `resyncPending` | No frame is planned for it. |
| A fresh ack arrives while the check that marks `resyncPending` is held | The check's decision stands for that pass. The next check resyncs. |
| An ack arrives between a close decision and the close | The session still closes, and the ack is dropped. |
| The player rejoins (new session, same player) while the old session's close is held | The new connection stays open. The close carries the old generation, and the transport drops it. |
| The session leaves or disconnects while its close is held | No double close. |
| An ack arrives before the session's firstSync commits (joining, or join pending, #224) | The ack is dropped, and no lag state is created by key. |
| A lag check runs while the session drains its flip, or while its leave is under way | No decision is made for it. |
| The session ends, and an ack for it arrives later (an old generation) | The ack is dropped, and no lag state is recreated by key. |

**Lag fixtures** (a controllable clock, no hold points needed):

| Case | Expected |
|---|---|
| Acks with an unchanged value every 1 s, lag past 3 s (slow reader) | `lastAckAt` stays fresh: an in-place resync at the first check past 3 s, never `resyncPending` or 4011. The player is still a member, and `OnLeave` never ran. |
| Silent 2.5 s with frames acked up to its start | No resync and no close. |
| Silent 5 s (elevator): the lag passes 3 s while silent | `resyncPending` at the first check past 3 s and no more frames planned. A snapshot at the first check after the acks resume, even if they ack everything received. Position and role are kept. |
| Silent 11 s | `resyncPending` from 3 s on, then an unresponsive close at 10 s. |
| Three resyncs within 60 s | The third is a slow-consumer close. |
| A snapshot that isn't acked within 10 s while the acks stay fresh | A slow-consumer close. |
| A join firstSync that takes 5 s to be acked while the acks stay fresh | No resync: a full view is exempt from the 3 s rule. |
| An idle land, no acks for 30 s, the FIFO empty | No close. |
| An idle land for 30 s without acks, then one frame, acked 1 s later through the apply path | No close: the timeout runs from the frame's commit. |
| A busy land with the ack timer throttled (no timer acks) | Apply-path acks keep it fresh: no `resyncPending`, no close. |
| A sparse land: one frame 5 s after the last acked one, acked within 1 s | Lag measured from that frame, so no resync. |

**Replay test.** A recorded live land with an in-place resync in it reevaluates with 0 mismatches: the resync's seed marker verifies against the replayed state.

## 4. Close codes

| Code | Name | Server cause (`SessionCloseCause`) | Client behavior |
|---|---|---|---|
| 4008 | backlog (existing) | `backlogBytes` / `backlogUnwritable` | unchanged: disconnect |
| 4010 | slow consumer | `slowConsumer` | disconnect, no auto-rejoin |
| 4011 | unresponsive | `ackTimeout` | disconnect, no auto-rejoin |

4009 isn't used: a resync no longer closes the connection. The constant is removed from `SessionClose.Code`, and the number stays unassigned.

**How they fit with 4008.** 4010 and 4011 come from the adapter's lag check, and 4008 from the handler's byte bound. Whichever fires first closes the session, and the handler's first recorded cause wins. With the defaults the lag check acts long before the bound, so 4008 remains the memory guard for a client whose acks are lying, or for a land with tracking off.

**The pong timeout (1001) stays as the transport keepalive.** With tracking on and frames unacked, the ack timeout (10 s) normally fires first for a silent peer. On an idle land the pong timeout is the only liveness check (§ 2).

The new causes go into the lifecycle log, the transport profile counters and the docs' cause table. **Counters:** `syncLagResyncs`, `syncLagResyncKeyScopeResets` and `syncLagResyncKeyScopeResetBytes` (the broadcast key-scope resets that resyncs request, coalesced per cycle, and the bytes they sent to all recipients), `syncLagDroppedEvents`, `slowConsumerCloses`, `unresponsiveCloses`.

**For step 6.** In slow-reader cells the healthy sessions receive those reset frames. The impairment topic reports the reset bytes separately for healthy sessions, so its per-session verdicts and byte columns don't read them as a regression.

**Configuration.** `EnvKeys.Server`, plus a `SyncLagPolicy` on `NIOLandServerConfiguration`, which the adapter receives:
- `SYNC_LAG_TRACKING` (default on);
- `SYNC_LAG_RESYNC_MS` (3000);
- `SYNC_LAG_SLOW_CONSUMER_COUNT` (3);
- `SYNC_LAG_SLOW_CONSUMER_WINDOW_MS` (60000);
- `SYNC_ACK_TIMEOUT_MS` (10000);
- `SYNC_ACK_FRESHNESS_MS` (2000): acks older than this pause the resync decision;
- `SYNC_LAG_CLOSE_GRACE_MS` (2000).

The client's interval is an SDK or ws-loadtest option, not a server setting. The server reports its configured timeout in `joinResponse`, so a client can check that its interval is well below it.

## 5. Clients and docs

**TS SDK (`sdk/ts`).** No reconnect is needed:
- Declare `syncSequence`.
- Decode `seq` in all encodings, and the resync update kind (opcode 3, `"type":"resync"`).
- Track `lastAppliedSeq` per view. Send acks on a runtime timer, and from the apply path once an interval has passed.
- **On a resync update, reconcile; don't clear and reapply.** Clearing first would fire `onRemove` for every map key and then `onAdd` for every key (`MapSubscriptions`, `core/index.ts`). A game that binds an object per key would destroy and recreate all of them: flicker, lost animation state, lost local references. Instead:
  - reset the per-player key map and rebuild the atomic values, as for a firstSync (`view.ts`, `decodeSnapshotValue`), and build the new state from the snapshot;
  - diff it against the current state: `onRemove` only for keys that are gone, `onAdd` only for new keys, and the normal per-path notifications for changed values, nested maps included;
  - replace the current state, and fire `onStateUpdate` once;
  - then fire a new `onResync` callback, as an optional hint: snap instead of interpolating, drop client-side prediction, show a brief indicator. A game that ignores it still ends up correct;
  - ack at once. Events emitted during the gap aren't delivered.
- On 4010 and 4011: `onDisconnect` gets the reason. No rejoin, as today.
- Tests: frame decoding with and without the feature, the ack cadence (timer and apply path), and no rejoin on 4010 and 4011. For the resync reconcile:
  - a key present before and after gets no remove or add, only its changes;
  - a key that is gone gets one `onRemove`, and a new key one `onAdd`;
  - nested maps the same;
  - the per-player key table and atomic values are rebuilt as for a firstSync;
  - an `onPatch` subscriber sees the same net changes;
  - `onResync` fires after the state is replaced.
- Codegen: only if the generated composables expose the new callback.

**ws-loadtest.**
- The same decode, ack and resync handling.
- 4010 and 4011 never trigger the reconnect path.
- Counters in the report: `resyncs`, `slowConsumerCloses`, `unresponsiveCloses` (`CloseSummary` already has `byCode`), plus `lastAppliedSeq` on close records.
- The two step-6 client fixes land in the step-6 change, not here.

**Other clients that join lands.** These must declare and ack too, or run against a server with tracking off: `Tools/CLI` (E2E), the Swift test clients that join, and the reevaluation monitor's client. A replay land gets the same tracking as a live land.

**Docs (English and zh-TW together).**
- `docs/transport/README.md`: the frame field, the `[108, seq]` ack in every encoding, the resync update, the close-code and cause table, the counters and the environment variables.
- `docs/sdk/README.md`: connection loss, `onResync`, and delivery semantics (a resync replaces the view in place, and events during the gap are lost).
- `docs/core/sync.md`: first sync and the resync snapshot.

## Open points for Review

1. *(Resolved: the resync count lives on the session, which survives an in-place resync. The resync token is gone.)*
2. **The lag check runs every 250 ms.** A decision can therefore land up to 250 ms past the threshold. ws-loadtest's expectation in step 6 is "about 3 s", within that.
3. **One PR: the server, the SDK, ws-loadtest and the `Tools/CLI` E2E clients together.** Review agreed. The required feature means that a server merged ahead of its clients would refuse every client that hasn't been updated, and CI's E2E clients are among them.
4. **Identity across a resync.** *Superseded on 2026-11-09.* The maintainer first chose option (a), a close-based resync whose token reclaims the player ID through a real `OnLeave` and `OnJoin`. With `resyncPending`, that would have turned a few seconds without signal during play into a new character. The maintainer then approved the in-place resync in § 3: the player never leaves, so identity, position and role are kept, and no token is needed. Keeping a player across a real disconnect is the separate reconnect-grace issue, #334.

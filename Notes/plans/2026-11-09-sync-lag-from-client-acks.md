# Sync lag from client acks: design note (2026-11-09)

Step 5 of [the core round](2026-11-09-core-round-and-full-rerun.md), issue #332. This note is for Review before any code. The maintainer's decisions are fixed. This note covers how they map onto the code.

Decisions, restated:
- every sync frame carries a sync sequence;
- the client acks the latest applied sequence about once a second;
- lag over 3 s closes the session with a new "resync" code, and the client rejoins and gets a firstSync;
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

**Why per land instead of per session.** A per-land value is the same for every recipient of a cycle, so the shared broadcast bytes stay shared. A per-session lag still comes out of it, because the server remembers which sequence it last sent to each session (§ 3). The acked value is compared against that session's own frames, never against frames other sessions received.

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

**The message.** A new client→server transport message kind, `syncAck`, with payload `{seq}`:
- opcode `108` in the opcode encodings (`[108, seq]`); 107 is server-only;
- `{"kind":"syncAck","payload":{"seq":N}}` in JSON.

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

## 3. Lag state: where it lives and how closes are decided

**Where it lives.** All lag state is in the land's `TransportAdapter`, the actor that plans and commits sync frames. It is outside keeper turns.

| State | Contents |
|---|---|
| `sentAt` ring | `syncSeq → commit time` for recent cycles, written in `commitSyncPhase`. Bounded by time: entries older than `resyncAfter + 2 s` are evicted. |
| per session (keyed by `SessionID`, guarded by the existing `sessionTickets` generation) | `lastSentSeq` (set at commit for each frame to that session), `ackedSeq`, `lastAckAt` (starts at the firstSync commit), and `closing` |
| per player (keyed by `PlayerID`, entries expire after the window) | resync times within `slowConsumerWindow` |

**Lag.**
- `lag = 0` when `ackedSeq >= lastSentSeq`.
- Otherwise `lag = now − sentAt[ackedSeq]`: the time since the newest sync the client has confirmed.
- If `sentAt[ackedSeq]` was evicted, the lag is past the threshold.
- The time is the commit to the writer, which is the point: bytes the kernel holds count as unacked.

**The check.** It is one synchronous pass over the sessions, with no `await`. It runs on a 250 ms adapter timer, which is a `safeTaskSleep` loop owned by the adapter's `Lifecycle`. The timer also covers tickless lands, which have no sync cycle to piggyback on.

| Condition (checked in this order) | Decision |
|---|---|
| `now − lastAckAt > ackTimeout` (10 s) | close with *unresponsive* |
| `lag > resyncAfter` (3 s), and this would be the player's `slowConsumerCount`-th resync (3rd) within `slowConsumerWindow` (60 s) | close with *slow consumer* |
| `lag > resyncAfter` | close with *resync*, and record the time for the player |

**Ticket handling.** This follows the CLAUDE.md reentrancy rule.
- In the synchronous pass, the adapter marks the session `closing` and captures its ticket (`sessionTickets.ticket`), together with the transport's connection generation for that session.
- From then on, in the same segment:
  - acks for the session are ignored;
  - no new sync frame is planned for it;
  - frames still queued for it in the adapter's writer are dropped.
- The decision is final once made. A late ack doesn't undo it.
- After the pass, the close goes out through the transport: `closeSession(id, code:, reason:, generation:)`. The transport acts only if the connection generation still matches, so a rejoined connection under the same player is never closed by a decision about its predecessor.
- When the close returns, any bookkeeping goes through `ifCurrent(ticket)`. That is the first production call site of `ifCurrent`.
- The per-player resync times are written in the synchronous pass, never after an `await`.

**The close path needs a code.**
- `Transport.closeSession`, `WebSocketConnection.close`, `NIOWebSocketConnection.close` and `WebSocketSessionHandler.close` gain `code:` and `reason:`, with defaults that keep today's 1000.
- The handler records the cause when it decides, before writing the frame, following the "cause recorded at a later callback" lesson.

**The close handshake.** For *resync* the handler writes the close frame, then waits up to `closeGrace` (2 s) for the client's close frame before closing the channel. `closeForBacklog` closes at once instead.
- Closing at once, with unread inbound data, makes the kernel send an RST.
- An RST can discard what is still unread in the client's receive buffer, the close frame included. The client would then see 1006 and wouldn't rejoin.
- At 3 s of lag the client has seconds of data to drain, not minutes, so the grace is enough.

**Hold-point tests.** New `TransportAdapterHoldPoint` cases at the close `await` and at the check timer. Every interleaving is forced with `HoldPoints` / `TestGate`, never with timing.

| Interleaving | Expected |
|---|---|
| An ack arrives between the decision and the close | The session still closes, and the ack is dropped. |
| The player rejoins (new session, same player) while the old session's close is held | The new connection stays open. The close carries the old generation, and the transport drops it. |
| A sync cycle commits while the close is held | No frame is planned for the closing session. |
| The session leaves or disconnects while the close is held | No double close, and no resync is recorded twice. |
| Two resync decisions for one player across a held close | The count is exact, and the third one is the slow-consumer close. |
| The session ends, and an ack for it arrives later (an old generation) | The ack is dropped, and no lag state is recreated by key. |

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
- `SYNC_LAG_CLOSE_GRACE_MS` (2000).

The client's interval is an SDK or ws-loadtest option, not a server setting. The server reports its configured timeout in `joinResponse`, so a client can check that its interval is well below it.

## 5. Clients and docs

**TS SDK (`sdk/ts`).** The SDK has no reconnect, so this is new work, not a reuse of an existing path:
- Declare `syncSequence`.
- Decode `seq` in all encodings.
- Track `lastAppliedSeq` per view, and send acks on a runtime timer.
- **On 4009:**
  - reopen the socket and rejoin every view with its land ID and the player ID from its join response;
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

1. **The resync budget is keyed by player ID.** That assumes a rejoin gets the same player ID: the SDK requests the ID from its join response, and the server keeps it unless auth overrides it. If guests can get a fresh ID on every join, the third-resync rule never fires. The fallback is a resync token in the 4009 close reason, which the client presents at rejoin.
2. **The lag check runs every 250 ms.** A decision can therefore land up to 250 ms past the threshold. ws-loadtest's expectation in step 6 is "about 3 s", within that.
3. **This is one PR, or a server PR with the SDK and ws-loadtest in the same PR.** The required feature means that a server merged ahead of its clients would refuse every client that hasn't been updated, and CI's E2E clients are among them.

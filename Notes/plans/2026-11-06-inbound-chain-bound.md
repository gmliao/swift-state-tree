# Bound a session's inbound task chain (#113)

Status: open (rev 2: rev 1 with its review folded in; see § Rev 2).

## Problem

`WebSocketSessionHandler` hands each session's connect, message batches and disconnect to `InboundTaskChain`. The chain runs them one after another, in order (#99, #112).

The chain has no bound. The channel keeps reading while an operation in the chain is slow, so frames pile up in queued batches with no limit. Slow operations include:

- a join awaiting land lookup or creation (the router's `onMessage` is suspended until its admission);
- a slow resolver;
- a tickless action held by a debug freeze.

Memory per batch is the same as before #112, but nothing stops the count of batches. Behind them wait every later batch and the session's disconnect: head-of-line latency.

#224 (4c) bounds what reaches the adapter: `JOIN_INBOUND_OVERFLOW` while a join is pending, and `INBOUND_OVERFLOW` behind the drain. Those bounds act only once a frame is in the adapter. Frames waiting in the chain in front of a suspended `onMessage` are not counted anywhere.

## Design

Backpressure on the channel, in the handler. Nothing here closes a session.

1. **Count what is queued.** The handler counts the messages and bytes it has handed to the chain that have not reached the transport yet. Both counts are event-loop state, like the handler's other `var`s:
   - `flushPendingMessages` adds a batch's count and bytes when it enqueues the batch.
   - After each message's `handleIncomingMessage` returns, the chain closure subtracts that message, with `eventLoop.execute`.
   - A rejected connection's batch subtracts all of its messages at once.
   - Messages still in `pendingMessages` (not flushed yet) count too, so the bound sees every message read and not yet delivered.
2. **Pause reads above the high watermark.** The handler becomes a `ChannelDuplexHandler` and intercepts the outbound `read(context:)`, as NIO's `BackPressureHandler` does for writability:
   - **Pausing.** While queued messages exceed `maxMessages`, or queued bytes exceed `maxBytes`, a `read()` is withheld (recorded as pending) instead of forwarded. With `autoRead` on, the channel then reads nothing more: TCP backpressure to the client instead of memory.
   - **Resuming.** When both counts are at or below half their limits (the low watermark), the pending `read()` is forwarded.
3. **The bound is soft.** Frames already decoded from bytes the channel has read are still delivered (`channelRead`) and queued. So the overshoot is at most one read's worth of frames, plus one reassembled message (`maxFragmentSize`, or a frame up to `maxFrameSize`). The tests assert the bound with that slack.
4. **The disconnect is not paused.**
   - `handlerRemoved` and `handleClose` still enqueue it (no read is involved). It still waits behind the queued messages, in order; a deadline for that wait is #104.
   - A pause doesn't hold up the close handshake or ping keepalive. Pings are writes, and a client's pong arrives only after reads resume. A stall longer than `pongTimeout` therefore closes the session with 1001, as for a dead client, which is the intended bound on a stuck operation until #104.
5. **Configuration.**
   - `InboundBacklogBound(maxMessages:maxBytes:)` goes on `NIOWebSocketServerConfiguration`, next to `SendBacklogBound`.
   - Env: `WS_INBOUND_BACKLOG_MAX_MESSAGES` and `WS_INBOUND_BACKLOG_MAX_BYTES`, read with the same helper pattern. 0 disables that bound.
   - Defaults: 1024 messages and 4 MiB. That is 16 full batches (`maxBatchSize` 64), far above a well-behaved client during a join, and below what a flood can grow to.
6. **Metrics.**
   - **Per handler:** `InboundBacklogStats`, with the largest queued count and bytes, the read pauses, and the longest pause.
   - **Profiler:** `TransportProfilerCounters` gets `noteInboundReadPauseStarted()` / `noteInboundReadPauseEnded(durationMs:)` (pauses, and time paused per window) and `noteInboundQueued(messages:bytes:)` (the window's max), mirroring the send-backlog counters. A load run then shows head-of-line effects.
7. **Out of scope.**
   - Deadlines on queued operations (#104).
   - Dropping queued messages on a disconnect (they are delivered, then the disconnect, as today).

## Tests (NIO, `EmbeddedChannel`)

A holding delegate suspends the first message. A counting outbound handler at the head of the pipeline records the `read()`s that reach the channel. No timing: the tests wait on the delegate's hold and on the chain (`waitForInboundIdle`).

1. **The bound holds.** A held message, then a flood of frames: after the high watermark, `read()` is withheld, and the queued counts stay within the bound plus the slack.
2. **Reads resume after the drain.** On release, the pending `read()` is forwarded once the counts reach the low watermark, and not before.
3. **Order is kept across the pause.** The delegate sees every message once, in the order written, then the disconnect.
4. **A disconnect while paused** still reaches the transport, after the queued messages.
5. **A rejected connection** drains its counts, so reads aren't withheld forever.
6. **Disabled bound** (0/0): `read()` is never withheld.
7. **Env parsing,** as for `SendBacklogBound`.

Each guard is mutation-checked: no withholding, no resume, and no subtraction for a rejected connection.

## Open for review

- **Bytes in the bound.** Should it count bytes at all? Messages alone are simpler, but one frame can be 16 MiB (`maxFrameSize`), so a message count alone doesn't bound memory.
- **The defaults.**
- **A long pause ends the session.** A pause that outlasts `pongTimeout` (20 s) closes the session, because no frame can be read to answer a ping. Is that the bound we want for a stuck operation until #104? The alternative is to keep reading control frames, but that requires reading data frames too, so it would not be a pause.

## Rev 2 (review of rev 1)

Review gave rev 1 a GO. The points below are folded in and take precedence over the sections above.

- **Bytes are counted.**
  - **The slack.** The bound is exceeded by at most 4 MiB + one maximum message: one frame (`maxFrameSize`) or one reassembled message (`maxFragmentSize`). The message that crosses the bound is queued, and so are the frames already decoded from the same read. The tests assert that slack.
  - **The bound is per session.** The aggregate is sessions × 4 MiB, and nothing here bounds it.
- **The defaults are kept:** 1024 messages and 4 MiB. The 1001 close after `pongTimeout` is the accepted interim bound on a stuck operation until #104.
- **§4 corrected: a withheld `read()` also withholds the client's own close.** Its close frame and its EOF are read only when reads resume, so "the disconnect is not paused" holds for server-side closes only.
  - **A client's close while paused** is seen when the reads resume, or when the pong timeout closes the session: up to about 50 s with 30 s pings.
  - **Server-side closes** are unaffected: #231's close-frame deadline and #225's send backlog bound act while paused.
  - **The test** drives `handlerRemoved` directly, so it shows the server-side case only.
- **Composition with 4c.** The chain bound trips only while the router's `onMessage` is suspended: during an admission, or an inline dispatch held by a slow resolver. Once the router returns after an in-turn admission, the frames go to the adapter. Its pending-join bound (256 frames, 256 KiB) trips first and closes the session with `JOIN_INBOUND_OVERFLOW`. A composed test covers this: a pending join plus 300 frames ends with `JOIN_INBOUND_OVERFLOW` and no read pause.
- **The decrement.**
  - **Off the loop.** The counts sit behind one lock (`InboundBacklogCounter`), shared by the loop, which adds, and the chain, which subtracts from any thread. The chain hops to the loop only when a paused backlog drains. An unpaused session therefore costs no loop task per batch.
  - **The resume** runs on the loop. It forwards the withheld read only if one is pending and the handler still has its context.


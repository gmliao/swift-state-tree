# Defined behaviour when a session's send queue backs up (#61)

Status: open. Step 1 (measurement) is done (#217). The maintainer chose **option A**: over the bound the session is closed and the client rebuilds from firstSync (#219 checks that the rebuild is exact). Step 3 below is next. B and rate-adaptive catch-up are deferred (#220, #221).

## Where the backlog is today

The send path, per session (main, 009fdea):

1. `TransportAdapter` enqueues frames into `WebSocketTransport` (`send`, `sendBatch`, `sendSessionFrames`), which yields them into the session's `AsyncStream<Data>`. It's unbounded (default buffering).
2. The session's drain task awaits `connection.send(data)`.
3. `NIOWebSocketConnection.send` hands the buffer to `WebSocketSessionHandler.send`, which calls `writeAndFlush(frame, promise: nil)` and returns. It doesn't wait for the write, and nothing reads `channel.isWritable` or `channelWritabilityChanged`.

So the drain task empties the `AsyncStream` at once. On a slow link, the data accumulates in NIO's `ChannelOutboundBuffer` (and the kernel send buffer before it), and **nothing bounds it**:
- The default `WriteBufferWaterMark` (32 KiB low, 64 KiB high) only flips `isWritable`, and nothing observes that.
- A client that stops reading costs server memory without limit, and receives every queued diff in order when it catches up.
- Nothing measures how much is pending.

Related defects found on the way:
- A failed `connection.send` makes the drain task `break` without finishing the stream, so later yields buffer silently until the disconnect.
- `handleConnection` overwrites `sessionQueues[sessionID]` without finishing the previous queue, which leaks its drain task when a `SessionID` is reused.
- In a land with no members, `_syncNowImpl` returns before `beginSync`, so pending server events grow without bound (from #77).

## Options

**A. Bound, then disconnect.**
- How: when a session's pending outbound bytes exceed a limit, or it stays unwritable for longer than a limit, close it with a dedicated close code (e.g. 4008 "send backlog"). The client reconnects, and the existing join path gives it a firstSync.
- For: small (bookkeeping in the NIO handler, one close code). No new sync semantics, and no SDK change beyond showing the code. The same thing Phoenix and Discord gateways do with slow consumers.
- Against: on an impaired link a lagging client is kicked out, which the impairment experiment would count as disconnects, against the zero-disconnect bar. Under sustained impairment it can also oscillate: reconnect, firstSync (the largest frame), back up again.

**B. Bound, then drop and resync.**
- How: past a soft threshold (unwritable, or pending bytes above a limit), the adapter stops sending that session state diffs and marks it `needsResync`. When the channel is writable again (below the low watermark), it sends one full view of the current state, through the late-join path (`planFirstSync`), and resumes diffs from there.
- Server events: they aren't state and can't be coalesced. They are kept up to a per-session cap; beyond it, the oldest are dropped and the resync frame carries a "dropped N events" marker.
- For: no disconnect. Bandwidth after a stall is one snapshot instead of every stale diff. It reuses the firstSync machinery.
- Against, all real work:
  - The SDK applies a firstSync's patches on top of its current state, and a firstSync from empty never removes keys. A resync needs the client to replace its state, either with a new update kind (`resync`) or with firstSync clearing the state first. Either is a wire and SDK change, coordinated across the TS SDK, the CLI and the codegen'd clients.
  - Dynamic key tables: the resync must reset the session's per-player key scope, and its broadcast key scope (#189's reset applies).
  - Sync-output recording and the verifier must record a resync as a seed, like a rejoin, so verification keeps working.
  - Broadcast diffs are computed once for all sessions. A skipped session simply misses them, and that's correct only because the resync replaces its view.

**C. Coalesce queued frames.** Merge pending state frames by path before they're written. Frames are encoded bytes with key-table state, so this means decoding and re-encoding per session. Not recommended: B gets the same effect more simply.

**D. Document unbounded behaviour.** Not acceptable, since memory grows without limit.

## Recommendation

**B, with A's disconnect as a hard backstop**, after a first step that measures.

1. **Measure first (small, core).** Track the per-session pending outbound bytes in the NIO handler: count on write, subtract in the write promise, and observe `channelWritabilityChanged`. Expose them:
   - in the adapter's profiler: max pending bytes, unwritable episodes and their duration;
   - in ws-loadtest's report.
   
   Fix the two drain-task defects above. This step changes no behaviour, and the impairment experiment needs these numbers to decide the thresholds. It also settles whether backlogs occur at the experiment's impairment levels at all.
2. **Drop and resync (core plus SDK).** Add the `resync` update kind and replace-state handling in the SDK. The adapter skips a `needsResync` session's diffs and sends its resync on writability. Events are capped with a dropped-count marker. The verifier records a resync seed. Thresholds are configurable (env plus `NIOLandServerConfiguration`), with defaults from step 1's data.
3. **Backstop.** Above a hard cap (e.g. 8 MiB pending, or unwritable for 30 s), disconnect with close code 4008. It's a memory bound for a client that never drains, not the normal path.

Why B over A: the impairment experiment's question is how sync behaves on a bad link. Under A, the answer is "it disconnects", and every backlog becomes a reconnect and a full firstSync, the most expensive frame, sent on the worst link. B keeps the session and sends one frame of the current state, which is what absolute patches allow. A stays only for a client that never drains.

If the maintainer wants the smallest change before the rerun, **A alone** is a coherent alternative (step 1, then step 3 with a lower threshold), and B later. The cost is that disconnects become part of the impairment results.

## Step 3: the bound (option A, decided)

**Bound.** Close a session when either holds:
- **bytes:** its channel's `bufferedWritableBytes` exceeds `sendBacklogMaxBytes`, default 8 MiB. This is checked where #217 samples, when the channel turns unwritable and after each write while it stays so, so the writable path stays one `isWritable` read;
- **time:** it stays unwritable for longer than `sendBacklogMaxUnwritable`, default 30 s. A timer is scheduled on the event loop when an episode opens, using #217's episode start, and cancelled when the episode closes.

Like Redis's `client-output-buffer-limit` (a hard limit), there is no soft limit here: B, the soft path, is deferred.

**Configuration.** `NIOWebSocketServerConfiguration.sendBacklogMaxBytes` and `.sendBacklogMaxUnwritable`, next to `pongTimeout`, set from `NIOLandHostConfiguration` the same way. The env keys go in `EnvKeys.Server`: `WS_SEND_BACKLOG_MAX_BYTES` and `WS_SEND_BACKLOG_MAX_UNWRITABLE_MS`, read with `EnvHelpers`. A value that is set but invalid is logged once and the default is used, as for `WS_PONG_TIMEOUT_MS`. 0 disables that bound.

**On breach.**
- `close(code: 4008)` ("send backlog"), through the existing `closeOnLoop`. No error frame comes first, so this doesn't depend on 4c's final-frame step. If 4c's close path lands first, this uses it.
- The close frame queues behind the backlog it is reacting to. So after writing it, the channel is closed at once, without waiting for the frame's write promise. A client that isn't draining will usually see the TCP close (1006), not 4008. The server's count is the reliable record; the code is best-effort and documented as such.
- It is counted in the profiler (`sendBacklogCloses`, per window), reported by ws-loadtest per phase, and logged at warning level with the session, the bound hit and the bytes.

**Interaction with the pong timeout.** A backed-up peer that sends nothing can hit the 20 s pong timeout (#108) before a 30 s unwritable bound. That's fine: either closes it, and the counters tell the two apart. The docs say so.

**Docs.** EN and zh-TW, `docs/transport/README`: the two bounds, the defaults, the env keys, the close code and its caveat, and how a client rebuilds (#219).

**Tests** (EmbeddedChannel, virtual time, no real sockets):
- bytes: unwritable with held writes above a small configured bound closes the channel and counts one close; just under the bound does not;
- time: unwritable, advance just under the bound, no close; then past it, close and count; becoming writable before it cancels the timer;
- a bound set to 0 disables it;
- config: env parsing, the invalid-value fallback and its one-time warning.

## Tests

- **Step 1:** pending bytes rise when a test channel doesn't drain, and return to 0 when it does (an `EmbeddedChannel` with writability toggled, no timing). The drain task finishes the stream on a send failure. A reused `SessionID` finishes the old queue.
- **Step 2, held writability (forced, no timing):**
  - diffs stop past the threshold;
  - one resync on writability, carrying the current state;
  - the client state equals the server view after it, keys removed during the stall included;
  - the event cap and its marker;
  - the verifier records the resync seed and replays with 0 mismatches.
- **Step 2, SDK vitest:** `resync` replaces the state and resets key tables.
- **Step 2, CLI E2E:** a scenario that pauses reading, then resumes and asserts convergence.
- **Step 3:** the hard cap closes with 4008.

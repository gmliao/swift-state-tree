# #911: one close per session, and an ended session's final frame doesn't overtake it

**Status:** rev 1, for Review (2026-11-26). Q1 and Q2 have the maintainer's default (the recommended answers); Review checks them. It builds on #913 (#909), which adds `closeSessionBehindQueuedFrames` and the close-only writer element. The code waits for #913 to merge.

## Problem

Three related gaps in the path that sends a session's last frame and closes it.

1. **An ended session's final frame closes at once.** `sendFinalFrameAndClose` (TransportAdapter+Outbound.swift:94) checks `endedSessions` first. For an ended session it drops the frame and calls `closeSessionDetached`, a `closeSession` from a task. That close retires the transport's per-session queue at once. If an ordered close is still pending behind frames (after #913, a superseded session's 4017), the plain 1000 overtakes it and those frames. P-911-2 (a) shows it on #913's head: A's 4017 waits behind a held frame, and A's connection gets `closed 1000` while the frame is still held.
2. **Which close wins is unwritten.** When a session has an ordered close pending and a second close is decided, the transport keeps the first: `closeMarkerYielded` makes a second `closeSessionAfterQueuedFrames` return (WebSocketTransport.swift:642). P-911-2 (b): a pending `sendFinalFrameAndClose` (1000), then a supersede: the client gets its frame, the error, then 1000, and no 4017. #913's docs state that case. Nothing states the rule.
3. **#912's test waits on a wall clock.** `pendingJoinOverflowsFirst` (WebSocketSessionHandlerInboundBacklogTests.swift:593) reads outbound frames for at most 5 s, looking for `JOIN_INBOUND_OVERFLOW`. On a slow macOS runner it saw 9 `JOIN_SESSION_NOT_CONNECTED` errors and not the overflow. That error is sent by `sendFinalFrameAndClose` through the path above, so a test that can't tell a slow frame from a lost one is a weak check of that path.

Consulted:
- `Notes/solutions/2026-11-18-a-server-close-goes-around-the-send-queue.md` (the bug class, at a third site);
- `2026-11-26-a-new-requirements-default-must-keep-the-older-requirement.md`;
- `2026-11-26-a-barrier-that-looks-up-live-state-skips-what-is-being-torn-down.md`;
- `2026-11-10-a-returned-send-is-not-a-delivered-frame.md` (the event wait, below);
- `2026-11-05-hold-points-not-timing-in-race-tests.md`.

## One Close frame

RFC 6455 lets an endpoint send one Close frame: "After sending a Close frame, the endpoint MUST NOT send any more data frames" (§5.5.1), and the closing handshake starts once (§7.1.2). The code already keeps that at three layers:
- `WebSocketSessionHandler.closeOnLoop` returns when `isClosed`: a second close writes no second frame;
- `WebSocketTransport.closeSession` returns when the session has no queue: the first close removed it;
- the close marker is yielded once per queue (`closeMarkerYielded`).

So the question is never "two Close frames", only which decision's code and order the one Close frame carries.

## The rule

**The first close decided for a connection is the one it gets.**
- An **ordered** close (behind queued frames: a final frame's, a supersede's) keeps its place and its code. A later ordered close for the same connection is ignored: its marker isn't yielded.
- An **at-once** close goes out at once, ahead of anything queued, by design. The sites, from #909's table, with the reason each skips the queue:
  - land failed, 4016: the output gate is closed and frames are dropped;
  - sync-lag, the code from #332: the client is behind, and waiting is what the close avoids;
  - writer ceiling drop: the dropped frames are why it closes;
  - stale registration refusal, and a join ended before admission without a final frame: no frames queued.

  An at-once close decided after a pending ordered one preempts it. That is the existing behavior, kept and now written down.
- **A final frame for a session that has already ended** sends no frame (as today: the session is ended) and decides no new close. It goes through the writer as an ordered `.normal` close (`closeSessionBehindQueuedFrames`). Three cases follow from the layers above:
  - an earlier ordered close is pending: it wins, with its code and its frames ahead of it;
  - an earlier at-once close already ran: the queue is gone, and nothing happens;
  - the client disconnected: the queue is gone, and nothing happens.

  The at-once path leaves this function except for the existing fallback, a writer that refuses the close after `finish`.

Why the writer, and not "skip the close when ended": P-911-1 found that every site that ends a session also decides its close, or the client is gone. So today both are the same. The writer route still closes in order if a future end site forgets to close, and it removes the only at-once close from a function whose contract is "the close can't overtake the frame".

## Design

1. `sendFinalFrameAndClose`'s ended branch calls `closeSessionBehindQueuedFrames(sessionID, generation: generation, with: .normal)` instead of `closeSessionDetached`. Generation and fallback are as #913 has them, and the function stays synchronous.
2. **Docs.**
   - `docs/transport/README.md` and `.zh-TW.md`: the rule, in one bullet next to the close codes. The first close decided is the one the client gets. An ordered close keeps the frames ahead of it. The at-once closes listed above don't wait. #913's 4017 sub-bullet becomes a case of the rule.
   - The doc comments of `Transport.closeSessionAfterQueuedFrames(_:generation:with:)` and of the adapter's `closeSessionBehindQueuedFrames` say that a second ordered close for the same connection is ignored.
3. **#912's test.** Replace the 5 s loop with an event wait. Read the channel's outbound writes with `NIOAsyncTestingChannel.waitForOutboundWrite(as: WebSocketFrame.self)`, which waits for the next write, until the `connectionClose` frame, collecting the error codes before it. Then expect:
   - `JOIN_INBOUND_OVERFLOW` among them, before the close frame;
   - the close frame's code: 1000, `sendFinalFrameAndClose`'s.

   The suite's one-minute limit bounds a hang. A slow runner then waits instead of failing. A lost frame fails with the close frame and no overflow error, which says what happened. The `waitUntilAsync` 5 s poll for `isJoinPending` (:613) becomes `pollUntil` (TestSupport, `testHangBound`), the polling helper the repository counts.

## The callers of sendFinalFrameAndClose

| Caller | Can the session already be ended? | Effect of the change |
|---|---|---|
| Router flip failure, `.timeout` / `.eventOverflow` / `.inboundOverflow` (LandRouter.swift:1427) | Yes. The failure is decided in the router, and `await pending.adapter.sendFinalFrameAndClose` hops into the adapter. A newer join of the player can supersede the session first (P-911-1). | The supersede's 4017 and its frames win; before, a 1000 overtook them (P-911-2 a) |
| Inbound overflow after the flip (`queueBehindDrain`, TA:2456) | No. It runs only while `inboundAfterFlip[session]` exists, and every end site removes it in the same segment. | None |
| Join ended before admission, with a frame (TA:1854) | Only after a disconnect. It is guarded by "no admission, not joining, no member" in the same segment. The one end site that leaves a session in that state is the disconnect, whose client is gone (P-911-1). | None: the close finds no queue, before and after |

## Tests (failing first)

In `SupersedeCloseOrderTests` (from #913), with `WebSocketTransport`, a held connection send and the bound held:
- **F1.** P-911-2 (a) as a test: A's last frame is held, A2 supersedes A, then `sendFinalFrameAndClose` for A. While the frame is held, A has no close. After the release, A gets the frame, then 4017, and nothing after it. Fails today: `closed 1000` while held.
- **F2.** P-911-2 (b), which pins the rule's other side: a pending final frame's close (1000), then the supersede. A gets its frame, the error, then 1000, and no 4017. Passes today; it fixes the rule against a later change.
- **F3.** An at-once close after a pending ordered one still goes out at once: A's frame is held and the supersede's 4017 is pending, then a sync-lag close (`endAndCloseSession`). A's connection gets the sync-lag code while the frame is held. Passes today, and pins the "at-once preempts" row.
- **#912.** The rewritten `pendingJoinOverflowsFirst`, the same expectations without a wall clock.

Mutant (cloud): the ended branch back on `closeSessionDetached`. F1 fails.

## Questions

| # | Question | Recommended |
|---|---|---|
| Q1 | In case (b), should the later 4017 replace the pending 1000, since its reason ("logged in elsewhere") says more? | No: keep "first decided wins". The error frame already tells that client why. Replacing a queued marker's code is a new mechanism, and it would make the code depend on which decision ran first. |
| Q2 | Fold #912's test into this PR, or a PR of its own? | This PR: it checks the same path, and the event wait shows whether #912 was slow or lost. #912 stays open until the PR's macOS job has passed it. |

## Probes

**P-911-1, a code read: which sites end a session, and does each decide a close?** `endedSessions.insert`, on #913's head:
- disconnect (TA:1300): the client is gone;
- stale registration refusal (:1503): closes at once;
- join ended before admission (:1856): closes at once, or a final frame;
- supersede (:1983): ordered 4017;
- land failure (:3730): at once, 4016;
- sync-lag (:3758): at once, with grace;
- writer ceiling drop (Outbound:79): at once;
- final frame (Outbound:103): ordered.

Each decides a close, or the client is gone. The only caller that can reach the ended branch is the router's flip failure, through a supersede between the router's decision and its hop into the adapter. Not run.

**P-911-2, run: two closes for one session, on #913's head (`030d2353`).** A temporary test (`2026-11-26-911-probe.swift`, next to this plan) with `WebSocketTransport`, the bound held, and a connection whose sends are held. Apple Swift 6.4.2, macOS, debug:
```text
probe-911 a: while held=["closed 1000 (plain)"] final=["closed 1000 (plain)", "sent A-last-frame"] atBound=0 droppedAfterMarker=0
probe-911 b: while held=[] final=["sent A-last-frame", "sent A-error-frame", "closed 1000 (plain)"] atBound=0 droppedAfterMarker=0
```
- (a): the supersede's 4017 waits behind the held frame, then `sendFinalFrameAndClose` on the ended session. The connection was closed with a plain 1000 while the frame was held, and no 4017 went out. The "sent" after the close is the probe connection finishing a send that was already in flight. A real connection has its handler closed by then.
- (b): the final frame's ordered 1000 is pending, then the supersede. The frame and the error go out, then 1000; the supersede's marker is ignored.

**P-911-3, a code read: what the #912 test can wait for.**
- `NIOAsyncTestingChannel.waitForOutboundWrite(as:)` (swift-nio, AsyncTestingChannel.swift:420) returns the next buffered write, or waits for one. It throws `ioOnClosedChannel` if the channel closes first.
- The handler writes the `connectionClose` frame in `closeOnLoop` (WebSocketSessionHandler.swift:960) before it closes the channel, and the marker's close calls it.

So the close frame is the event after the final frame. Not run: it is run as the rewritten test in the PR.

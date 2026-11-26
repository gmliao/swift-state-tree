# #909: a superseded session's close can overtake its last queued frame

**Status:** rev 2, for Review (2026-11-26): Review's rev 1 GO with two shoulds and a nit, folded (see Changelog).

## Problem

A newer join of a player supersedes the player's older session (`supersedeSessions`, TransportAdapter.swift:1935, #531). In the same segment it:
- ends the old session (`endedSessions`, so later frames for it are dropped at the enqueue);
- closes the old session with 4017, from a detached task: `closeSessionDetached(old, generation:, with: .superseded)` → `Task { await transport.closeSession(…) }` (:1526).

That close doesn't go through the adapter's outbound writer. A frame already enqueued for the old session is still ahead of it in two queues:
- the writer's stream (`OutboundWriter`);
- the transport's per-session queue (`WebSocketTransport`).

`closeSession` closes at once and retires the session's queue, so the close can overtake the frame. Then the client never receives a frame the server sent, and the record holds it.

The differential harness's `second-session` row shows it (#908): on a duplicate login, the kick's leave turn enqueues A's last update (`[2,3,["/notes",2],["/players",1,[]]]`). Then A2's registration supersedes A. In a cloud stress run on Linux, 3 of about 15000 runs lost the frame, with every sync output and counter unchanged.

It is the bug class of `Notes/solutions/2026-11-18-a-server-close-goes-around-the-send-queue.md` (the handshake's 1009 close), at another site. Consulted too:
- `2026-11-10-a-returned-send-is-not-a-delivered-frame.md`;
- `2026-11-06-protocol-extension-default-wins-overload-resolution.md` (see P-909-1).

## Prior art

An orderly close goes behind the data already queued:
- **TCP:** the FIN follows the queued data. "TCP will reliably deliver all buffers SENT before the connection was CLOSED" (RFC 793 §3.5, kept in RFC 9293 §3.6).
- **WebSocket:** the Close frame is the last frame its side sends. "After sending a Close frame, the endpoint MUST NOT send any more data frames" (RFC 6455 §5.5.1).
- **Netty:** `writeAndFlush(msg).addListener(ChannelFutureListener.CLOSE)`.
- **SwiftNIO:** `context.writeAndFlush(…).whenComplete { _ in context.close(promise: nil) }`, rather than `close()` with pending writes, which fails them.

This repository already has the ordered close: `sendFinalFrameAndClose` puts the close in the writer element behind its frame (`closingSessions:`). The writer then calls `Transport.closeSessionAfterQueuedFrames`, which yields a close marker into the session's queue, bounded by `JoinFlipConfig.finalFrameCloseTimeout`.

## Design

The supersede's close goes through the writer, behind every frame already enqueued for the session, the way `sendFinalFrameAndClose` does it, but with no frame of its own.

1. **A close-only writer element.** `OutboundWriter.enqueue` returns `.accepted` for empty frames without yielding (OutboundWriter.swift:224). Add `enqueueClose(_ closing: [ClosingSession]) -> OutboundEnqueueResult`. It yields an element with no frames:
   - The element is not a sync cycle, so the back-pressure rule (`hasPendingStateElement`, which counts `syncCycleElements`) doesn't see it.
   - It adds 0 bytes. It counts as an element, so the backlog's element count and the writer's flush see it.
   - After `finish` it returns `.droppedAfterFinish`, as `enqueue` does.
2. **The close code travels with it.** `ClosingSession` gains `close: SessionClose` (default `.normal`, so `sendFinalFrameAndClose` is unchanged). The consumer calls `closeSessionAfterQueuedFrames(sessionID, generation:, with: close)`.
3. **The transport's ordered close takes the code.** `Transport` gains the requirement `closeSessionAfterQueuedFrames(_:generation:with:)`.
   - **Its default keeps the older ordered closes.** `Transport` already has `closeSessionAfterQueuedFrames(_:)` (Transport.swift:83) and `(_:generation:)` (:88, whose default calls the one-argument one, :116). After step 2 every closing element calls the new three-argument one, `sendFinalFrameAndClose`'s `.normal` included. A default that closed at once would drop the ordering for a conformer that implemented only the one- or two-argument close. So the default forwards to `closeSessionAfterQueuedFrames(_:generation:)` when `close == .normal`, and closes at once with the code (`closeSession(_:with:generation:)`) otherwise. The second branch is today's behavior for the supersede: a transport without the new method closes it at once, as now. P-909-1 checks both branches.
   - `WebSocketTransport`'s existing `package` method of that signature (WebSocketTransport.swift:630) becomes `public`, the witness.
   - Without the requirement, a call through `any Transport` would reach the extension default (the 2026-11-06 lesson). P-909-1 checks this.
   - This is an additive public API change, with a default.
4. **`supersedeSessions` closes through the writer.** It calls a new `closeSessionAfterQueuedFrames(old, generation:, with: .superseded)` on the adapter. That function:
   - enqueues the close-only element;
   - falls back to `closeSessionDetached` when the writer refuses it (finished, or over its ceiling), as `sendFinalFrameAndClose` does.

   The function is synchronous, and must stay so: the enqueue, the decision to fall back and the fallback run in one segment, with no `await`, so nothing can enqueue for the session or change its generation between them. It runs inside `supersedeSessions`, which is already synchronous.

   The generation is the one captured before `connectionGenerations[old]` is removed. #531's rule carries over: the close acts only on that connection (the writer passes it, and the transport's marker and bound both check it).

The rest of the supersede is unchanged. It is still synchronous, and the session is ended in the same segment, so no new frame is enqueued for it after the close element.

**What a client sees.** A superseded client gets the frames that were queued for it, then the 4017 close. A client that stopped reading is closed at the bound, as for a final frame.

**Test support: #908's barrier.** The harness waits for "the supersedes' closes" through `waitForDetachedClosesForTesting` (DiffRunner.swift:586). After the change, the close is the writer's, and the barrier is: **wait until each superseded session's connection has received its 4017 close** (the drain reached the marker and the close ran), through the connection's `waitUntilClosed()` (RecordingConnection.swift:67), and check its code. A wait for the writer to drain is not enough: the writer has then handed the close to the transport, but the transport's per-session queue may not have sent the frames ahead of the marker yet, so the harness could read A's frames before the last one arrives. `waitForDetachedClosesForTesting` stays for the fallback path.

## The closes, and which go through the writer

| Site | Today | After | Why |
|---|---|---|---|
| `supersedeSessions` (TA:1962), 4017 | detached, at once | **ordered, through the writer** | this issue: the frames queued for it were sent to a client still connected |
| `sendFinalFrameAndClose` (Outbound:101) | ordered, through the writer | unchanged | already the pattern |
| `sendFinalFrameAndClose`, session already ended (Outbound:96) | detached, at once | unchanged | the session's earlier close is already queued. If that was an ordered close, the marker's `closeMarkerYielded` doesn't stop this one, which closes at once. A known limit, listed for Review (Q2) |
| `sendFinalFrameAndClose`, writer refused (Outbound:105) | detached, at once | unchanged | nothing can be ordered behind a finished or full writer |
| writer ceiling drop (Outbound:80) | at once | unchanged | the dropped frames are why it closes: the client must rejoin |
| stale registration refusal (TA:1507) | detached, at once | unchanged | the session never became a member and has no state frames |
| router join abandoned, no final frame (TA:1827) | detached, at once | unchanged | no admission, no frames for it |
| inbound overflow, error didn't encode (TA:2429) | at once | unchanged | the fallback of an ordered close |
| land failed, 4016 (TA:3715) | at once | unchanged | the output gate is closed and every frame is dropped (#696); the 4016 goes out alone |
| sync-lag close (TA:3739) | at once, with grace | unchanged | the client is behind; waiting for its queue is what the close avoids (#332) |
| row-addressing refusal, 1011 (TA:5238) | at once | unchanged | the join is refused before its first sync |

## Tests (failing first)

In `TransportAdapterRegisterSessionTests` or a new `SupersedeCloseOrderTests`, with a `WebSocketTransport` whose connection's `send` waits on a `TestGate`, the shape of `HandshakeFrameLimitTests`:
- **S1.** Session A is joined. A frame is enqueued for A, and its `send` is held. A second join of A's player supersedes A. While the send is held, no close has reached A's connection. After the release, A's connection has the frame, then the 4017 close. Today the close arrives while the frame is held: S1 fails first.
  - **The bound can't stand in.** The ordered close is bounded by `JoinFlipConfig.finalFrameCloseTimeout` (1 s by default). While the send is held, that timer would close A at the bound, and "no close while held" would race it. S1 holds the bound's check instead: `setDelayedCloseForTesting` arrives at a `TestGate` on `.willCheck(.bound)`, which S1 never opens before its checks, as `boundClosesAreCounted` (HandshakeFrameLimitTests.swift:427) does. At the end S1 also expects `finalFrameClosesAtBound == 0`: the close ran at the marker, not at the bound.
- **S2.** The generation pin (#531): A's ordered close, held at the drain, doesn't close a newer connection that reuses the ID. This uses `setDelayedCloseForTesting`, as the 2026-11-18 lesson says.
- **S3.** The fallback: with the writer finished, the supersede still closes A, at once.
- **S4.** P-909-1's dispatch, in the suite: through `any Transport`, `WebSocketTransport`'s `closeSessionAfterQueuedFrames(_:generation:with:)` closes with the code it was given (4017), not 1000.

The full `swift test` includes the differential harness. Its goldens should not change, since the fix makes the golden's order the only one. The pinned-image CI job compares bytes. Probe908's stress row reruns in the cloud after the merge.

Mutants (cloud):
1. `supersedeSessions` back on `closeSessionDetached`: S1 fails.
2. The consumer drops `with: close`: S4 fails, and the 4017 becomes 1000.
3. The generation dropped from the close element: S2 fails.
4. `WebSocketTransport`'s witness back to `package`: build error, not a mutant. P-909-1 covers the overload.

## Docs

No `docs/` page describes the supersede's close order. The `Transport` requirement's doc comment says what the default does. `Notes/solutions/2026-11-18-…` gets a line pointing to this site, in the PR.

## Questions

| # | Question | Recommended |
|---|---|---|
| Q1 | The new `Transport` requirement is public API (additive, with a default). Accept it, or keep the code out of the protocol (a `package` protocol refinement that `WebSocketTransport` adopts)? | the requirement: every transport with an ordered close should honor the code, and the default keeps others compiling |
| Q2 | `sendFinalFrameAndClose` on an already-ended session closes at once and can overtake an earlier ordered close's frames. Fold that into this PR? | a separate issue: its reach is unproven, and this PR stays one site |

## Probes

**P-909-1: the new requirement dispatches to the conformer's method through the existential, and its default keeps an older conformer's ordering.** A protocol `Port` with an at-once close, a two-argument ordered close and the new `with:` ordered close, all defaulted in an extension as step 3 says. Three actors conform:
- `Concrete` implements both ordered closes (`WebSocketTransport` after #909);
- `OlderOrdered` implements only the two-argument one (a transport written before #909);
- `Plain` implements none.

Each gets the new call through `any Port`, with `.normal` and with 4017. Expected:
- `Concrete` runs its own `with:` both times;
- `OlderOrdered` gets its two-argument ordered close for `.normal` (rev 1's default would have closed it at once), and the at-once close with 4017;
- `Plain` gets the at-once close both times.

File: `2026-11-26-909-probe.swift`, next to this plan.

Ran with Apple Swift 6.4.2 (macOS), `swiftc -swift-version 6`:
```text
-- concrete
concrete ordered with: 1000
concrete ordered with: 4017
-- older
older ordered 2-arg
default at once: 4017
-- plain
default at once: 1000
default at once: 4017
```
Each line is what step 3 expects. `OlderOrdered` keeps its ordered close for `.normal` through the new call, which rev 1's default (close at once) would have dropped.

## Changelog

- rev 2: Review's should 1, the default chain: the new requirement's default forwards `.normal` to the two-argument ordered close, and P-909-1 gains a conformer with only that one. The adapter's new function is synchronous (enqueue, decision and fallback in one segment). Should 2: #908's barrier is the superseded connection's 4017, received. The nit: S1 holds the bound's check at a gate, and checks no close ran at the bound.
- rev 1: P-909-1, the existential dispatch (Apple Swift 6.4.2): `concrete with: 4017 / default with: 4017 / concrete with: 4017`.

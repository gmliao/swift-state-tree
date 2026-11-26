# #909: a superseded session's close can overtake its last queued frame

**Status:** rev 1, for Review (2026-11-26).

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
3. **The transport's ordered close takes the code.** `Transport` gains the requirement `closeSessionAfterQueuedFrames(_:generation:with:)`. Its default calls `closeSession(_:with:generation:)` at once, as the other default closes at once today.
   - `WebSocketTransport`'s existing `package` method of that signature (WebSocketTransport.swift:630) becomes `public`, the witness.
   - Without the requirement, a call through `any Transport` would reach the extension default (the 2026-11-06 lesson). P-909-1 checks this.
   - This is an additive public API change, with a default.
4. **`supersedeSessions` closes through the writer.** It calls a new `closeSessionAfterQueuedFrames(old, generation:, with: .superseded)` on the adapter. That function:
   - enqueues the close-only element;
   - falls back to `closeSessionDetached` when the writer refuses it (finished, or over its ceiling), as `sendFinalFrameAndClose` does.

   The generation is the one captured before `connectionGenerations[old]` is removed. #531's rule carries over: the close acts only on that connection (the writer passes it, and the transport's marker and bound both check it).

The rest of the supersede is unchanged. It is still synchronous, and the session is ended in the same segment, so no new frame is enqueued for it after the close element.

**What a client sees.** A superseded client gets the frames that were queued for it, then the 4017 close. A client that stopped reading is closed at the bound, as for a final frame.

**Test support.** The harness waits for "the supersedes' closes" through `waitForDetachedClosesForTesting` (DiffRunner.swift:586). After the change, the close is the writer's. The barrier waits for the writer to drain and for the transport's queue to reach the marker, as `flushOutbound` does. A detached close remains only on the fallback path. The exact wait is chosen in the PR, and the barrier's comment names it.

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

**P-909-1: the new requirement dispatches to the conformer's method through the existential.** A protocol `Port` with a two-argument requirement and a new `with:` requirement, both defaulted in an extension. An actor conforms with public methods of both signatures; another has none. Calls go through `[any Port]` and through the concrete type. Expected: the conformer's `with:` runs through the existential, and the default runs for the plain one. File: `2026-11-26-909-probe.swift`, next to this plan.

Ran with Apple Swift 6.4.2 (macOS), `swiftc -swift-version 6`:
```text
concrete with: 4017
default with: 4017
concrete with: 4017
```
Through `any Port`, the conformer's `with:` runs, and the default runs only for the type without one. So the requirement makes `WebSocketTransport`'s method reachable from the writer's `any Transport`. Without the requirement, the existential call resolves to the extension's method (the 2026-11-06 lesson); the probe doesn't rerun that negative.

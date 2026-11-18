---
module: SwiftStateTreeTransport
date: 2026-11-18
problem_type: bug_class
component: outbound-send-path
symptoms:
  - "a client is closed with the right code but never gets the error sent just before"
  - "a refusal test passes alone and fails in the full suite"
root_cause: close_bypasses_the_session_send_queue
resolution_type: established_pattern
severity: medium
tags:
  - ordering
  - send
  - close
  - session-queue
related:
  - "2026-11-04-same-session-frames-overtake-each-other"
---

# A server close goes around the send queue

## Problem

The pre-handshake frame-size cap sends an error, then closes the session with 1009. The test
expected one INVALID_MESSAGE_FORMAT error and the close. It passed alone; in the full suite the
close arrived and the error didn't.

## Root cause

`WebSocketTransport.send` only enqueues: the session's drain task hands the frame to the
connection later. `closeSession` doesn't go through that queue. It retires the queue and closes
the connection at once, so a frame still queued is dropped. Under load the drain hadn't run yet.

## Fix

Close behind the queued frames: `closeSessionAfterQueuedFrames(_:generation:with:)` yields a close marker
into the session's queue and the drain closes when it reaches it, with the given `SessionClose`
(bounded by `JoinFlipConfig.finalFrameCloseTimeout` for a client that stopped reading). Before,
that path always closed with 1000.

## Prevention

- An error that explains a close goes out with `closeSessionAfterQueuedFrames`, never
  `send` + `closeSession`. Pin both to the connection's generation: the bound's timer and the
  drain's marker callback can outlive the connection, and a reused `SessionID` is a new one.
- Test the order by holding the drain, not by load: a connection whose `send` waits on a gate.
  With the error held, check that no close has arrived, then release it and expect the error
  followed by the close. Also cover a drain that has already ended (the marker can't be read,
  so the close goes out at once), with a bound the test can't reach, so the ordinary bound
  can't stand in for that branch.
- Test a generation pin by making the stale callback run against a reconnected ID, held at
  the callback (`setDelayedCloseForTesting`). A client that leaves while the drain is held
  doesn't do it: the disconnect cancels the drain, so the marker is never read, and the bound
  fires after the test has ended. Remove the pin and check the test turns red.
- A refusal that closes a session also makes it terminal in the same segment, before the first
  await: until the close goes out, the client can still send, and a frame read in that window
  must not join.

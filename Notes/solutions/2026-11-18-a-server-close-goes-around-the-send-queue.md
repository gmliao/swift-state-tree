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

Close behind the queued frames: `closeSessionAfterQueuedFrames(_:with:)` yields a close marker
into the session's queue and the drain closes when it reaches it, with the given `SessionClose`
(bounded by `JoinFlipConfig.finalFrameCloseTimeout` for a client that stopped reading). Before,
that path always closed with 1000.

## Prevention

- An error that explains a close goes out with `closeSessionAfterQueuedFrames`, never
  `send` + `closeSession`.
- A test of a refusal checks both the error frame and the close code, and runs in the full
  suite: the race doesn't show when the test runs alone.

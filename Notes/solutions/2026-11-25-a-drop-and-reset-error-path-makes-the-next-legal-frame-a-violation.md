---
module: SwiftStateTreeNIO
date: 2026-11-25
problem_type: bug_class
component: websocket-fragment-reassembly
symptoms:
  - "a legal fragmented WebSocket message over the reassembly limit closes the connection with 1002"
  - "close cause .error for a peer that broke no protocol rule"
  - "an oversized message crossed on its last fragment is dropped and the connection stays open"
root_cause: error_path_resets_parser_state_without_failing_so_a_stricter_check_misreads_the_next_input
resolution_type: design_rule
severity: medium
tags:
  - websocket
  - rfc6455
  - fragmentation
  - parser-state
  - stricter-check
  - error-path
  - testing
related:
  - "#822"
  - "#827"
---

# A drop-and-reset error path makes the next legal frame a violation

## Problem

#822 made the fragment reassembler refuse a continuation frame with no unfinished message
(1002, RFC 6455 §5.4). An older path already reset that same state: a fragmented message past
the 1 MiB reassembly limit cleared the buffer and returned `.exceededMaxSize`, which the
session handler only logged. The peer's next continuation of the oversized message, legal on
the wire, then met the new check as an orphan, and the connection failed with 1002 and cause
`.error`. Crossed on the final fragment instead, the message was dropped silently and the
connection stayed open.

## Root cause

The new refusal reads state ("is a message unfinished?") that an existing error path resets
without ending the exchange. Before the stricter check, the reset was harmless: a stray
continuation was ignored. After it, the reset turns the peer's next legal input into a
violation the peer didn't commit, with the wrong code and cause.

## Fix

#827: `.exceededMaxSize` fails the connection with 1009 (RFC 6455 §7.4.1) through one
`failConnection(code:)` helper, now shared by every protocol failure (RSV bits, reserved
opcode, bad fragment sequence, message too big, invalid UTF-8, and `handleClose`'s three
malformed-close branches: 1-byte payload, invalid close code, non-UTF-8 reason): drop the
unfinished message, record cause `.error` with the code, send the close, queue the disconnect.
Handler tests cover an oversized first fragment, a crossing mid-message and a crossing on the
final fragment, each followed by a continuation, expecting 1009.

## Prevention

- When a check becomes stricter about some state, list every path that resets or clears that
  state. Each must either end the exchange (fail, close) or keep enough state for the next input
  to be judged correctly. A "drop it and carry on" path is the one to look for.
- Test the reset path with the input that legally follows it (here, the continuation after the
  oversized fragment), and assert the code, not only that the connection closed.
- On `EmbeddedChannel` a close write completes at once, so `handlerRemoved` queues the
  disconnect even if the failure path forgot to. To pin that the failure itself queues it, hold
  the close frame's flush (an outbound handler that doesn't flush) and assert the disconnect
  arrives before release.

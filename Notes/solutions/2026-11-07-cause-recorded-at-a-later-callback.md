---
module: NIO session handler, diagnostics
date: 2026-11-07
problem_type: logic_error
component: WebSocketSessionHandler
symptoms:
  - "A connection the peer reset is logged with a server-side cause (a kick, a pong timeout)"
  - "A close line is logged before the join line of the same connection"
root_cause: cause_recorded_at_a_later_callback_than_the_event
resolution_type: code_fix_and_rule
severity: medium
tags:
  - nio
  - diagnostics
  - ordering
  - first-cause
  - measurement
related:
  - "Sources/SwiftStateTreeNIO/WebSocketSessionHandler.swift"
  - "Tests/SwiftStateTreeNIOTests/SessionLifecycleLogTests.swift"
  - "https://github.com/gmliao/swift-state-tree/pull/265"
---

# A cause recorded at a later callback than the event loses to a decision in between

## Problem

The session lifecycle log (#265) writes one `sessionClosed` line per connection, with the first cause decided. The first version recorded `connectionLost` in `handlerRemoved`.

Review found two ways the record misattributes:
- **The gap after `channelInactive`.** NIO runs `handlerRemoved` a tick after `channelInactive`. In that gap the channel is gone, but the handler still has its context and isn't marked closed. A transport close queued through `eventLoop.execute`, or a pong deadline that comes due, records its own cause first, and the real cause (the peer reset) is dropped.
- **Order across components.** A close decided on the event loop is logged at once, while a join frame read before it still completes in its land afterwards. So a "close belongs to the latest join before it" rule finds no join.

## Root cause

A first-cause record is only as good as the point where it's taken. The fact (the connection went away) happened at `channelInactive`; recording it at a later callback leaves a window where any decision can claim first place. Likewise, two lines written by components running at different times have no reliable order, even when the events they describe do.

## Fix

- Record the cause in the callback where the event happens (`channelInactive`), and mark the handler closed there. Keep the later callback (`handlerRemoved`) as an idempotent fallback.
- Classify `errorCaught` before closing: a reset, broken pipe or timeout is `connectionLost`; anything else is its own cause (`error`), not folded into another.
- Pair records from different components by a key unique to the instance (`sessionID`, a UUID per connection), never by their order in the file.

## Prevention

- For every "first cause" or "first event" record, ask which callback the event itself happens in, and record there. Test the gap: fire the event, inject a competing decision before the later callback, and assert the record exists at the event, not only after cleanup.
- When two components log related lines, document the pairing key and state that order isn't guaranteed. Test it with a hold that delays one component past the other.
- In NIO, `ChannelError.eof` never reaches `errorCaught` (the pipeline asserts against firing it); an EOF ends in `channelInactive`.

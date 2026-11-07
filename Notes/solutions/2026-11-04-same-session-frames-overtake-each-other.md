---
module: SwiftStateTreeTransport
date: 2026-11-04
problem_type: bug_class
component: outbound-send-path
symptoms:
  - "A client ends up with a stale field value until that field changes again"
  - "A join response arrives after firstSync, or an action response before the state it reports"
  - "Order-dependent failures that come and go between runs"
root_cause: several_unordered_send_routes_per_session
resolution_type: architectural_fix
severity: high
tags:
  - ordering
  - send
  - outbound-writer
  - unstructured-task
  - sync
related:
  - "#60"
  - "#84"
  - "#86"
---

# Frames for one session overtake each other

## Problem

Clients apply patches in arrival order, and patches are absolute (`.set` / `.delete`), so an older update applied after a newer one leaves the client on a stale value until the field changes again (#60). Frames reached the transport by several routes: the transport's polling send queue (not awaited), one unstructured `Task { await transport.send(...) }` per session for the merged broadcast frame, and direct `send` calls with `Task.yield()`. Two unstructured tasks for the same session in cycles N and N+1 have no ordering guarantee when they hop onto the transport actor, and back-to-back cycles, immediate events and action responses could reorder.

## Root cause

An unstructured `Task` per send gives no order between sends. Ordering held only as long as the scheduler happened to run tasks in creation order.

## Fix

#86 sends every adapter frame through one ordered FIFO per land, `OutboundWriter` (`Sources/SwiftStateTreeTransport/OutboundWriter.swift`):

- every adapter send is a synchronous `enqueue` on the writer;
- one consumer task hands each element to the transport and awaits it before taking the next;
- a sync cycle never awaits the transport, and its frames, plus any frame issued while it runs, form one element;
- the join response goes through the same writer, so it precedes firstSync;
- the backlog is bounded per land (`OUTBOUND_WRITER_MAX_BYTES`, default 64 MiB), and a drop is never silent: the sessions it addressed are closed, so their clients reconnect and get a fresh firstSync.

The same PR also closed a cross-land leak (#84): the writer API takes `SessionFrame` (data + `SessionID`), so a group target can't be written, and the adapter expands `.all` / `.player` from its own membership.

## Prevention

- Anything order-sensitive per session goes through one serial queue. Never `Task { await send(...) }` per frame.
- Test with many back-to-back cycles under concurrency and assert per-session cycle order, or that the client state matches the server projection at the end.
- In tests, record frames synchronously in the transport (see [test recorders reorder frames on Linux](2026-11-05-async-test-recorder-reorders-frames-on-linux.md)).
- The ordered writer also removed a shared serialization point; see [shared serialization point collapses under saturation](2026-11-06-shared-send-serialization-point-collapses-under-saturation.md).

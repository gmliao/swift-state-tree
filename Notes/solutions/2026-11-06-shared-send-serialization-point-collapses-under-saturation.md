---
module: SwiftStateTreeTransport
date: 2026-11-06
problem_type: performance_collapse
component: outbound-send-path
symptoms:
  - "Near CPU saturation, RTT and input-to-visible latency grow to seconds instead of tens or hundreds of milliseconds"
  - "Most inputs are superseded before the client sees them; joins stop being answered"
  - "Another build at the same server CPU keeps up"
root_cause: shared_serialization_point_with_unbounded_fan_out
resolution_type: architectural_fix
severity: high
tags:
  - performance
  - saturation
  - backpressure
  - outbound-writer
  - queueing
related:
  - "#86"
  - "#91"
  - "#114"
---

# A shared send serialization point collapses under saturation

## Problem

In [the server A/B topic](../../deep-research/multiroom-load-2026-11-server-ab/README.md), step 4, at 1000 Hero Defense rooms with MoveTo at 2/s per player, both builds ran at about 747 % of the 8 pinned CPUs. The older build (A, `b629861`) fell behind: RTT p50 7.0 s, input-to-visible p50 2.1 s, and 375,288 of 485,685 inputs superseded before they were seen. The newer build (B, `ee8a407a`) kept up: RTT p50 158 ms, input-to-visible p50 191 ms, 0 superseded. Same CPU, very different behaviour: a queueing collapse, not a capacity limit.

## Root cause

Before #86, one `WebSocketTransport` actor served every land of a type. Each sync cycle spawned one unstructured task per session for the merged broadcast frame, other frames were separate awaited sends, and the transport drained a polling send queue with no backpressure. Under saturation, all lands contended for one actor, and the number of pending hops grew with sessions × cycles instead of being bounded.

## Fix

#86's ordered per-land `OutboundWriter` (see [same-session frames overtake each other](2026-11-04-same-session-frames-overtake-each-other.md)) changed the shape:

- one batch per land per cycle, so one hop onto the transport per land per cycle;
- the cycle enqueues synchronously and never awaits a send;
- a byte bound per land, with a visible close instead of unbounded growth.

Evidence that the writer, not the keeper-side changes, is what matters here: in the A/B topic's D6, build B with `IN_TURN_SYNC=false` (L, the legacy sync path, still with the writer) keeps up at the same load as the default, with every input seen. A bisect between A and B located the change at #86 (`ba76ca21`), which predates #91 and #114; its data isn't in a public topic yet, so treat that attribution as provisional.

## Prevention

- The rule behind it is the same as the turn rule, applied at the I/O boundary: code that produces output doesn't wait for I/O. Hand frames to a bounded, ordered queue owned by one consumer.
- Don't put a per-frame `Task` or a per-frame actor hop on a hot path that every land shares.
- Measure under saturation, not only below it: the collapse is invisible at 100–500 rooms, where both builds have similar latency.

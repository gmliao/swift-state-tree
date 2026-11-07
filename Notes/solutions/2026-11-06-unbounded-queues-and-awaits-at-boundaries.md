---
module: SwiftStateTreeTransport, SwiftStateTreeNIO, SwiftStateTree
date: 2026-11-06
problem_type: bug_class
component: transport-boundaries
symptoms:
  - "Server memory grows with a slow or stalled client"
  - "One slow OnJoin, OnLeave or resolver blocks every later join and leave of the land"
  - "A client waits forever for a join answer; a CI run hangs for over an hour"
root_cause: missing_bound_or_deadline_at_a_component_boundary
resolution_type: design_rule
severity: high
tags:
  - backpressure
  - deadline
  - timeout
  - bounded-queue
  - head-of-line
related:
  - "#61"
  - "#104"
  - "#113"
  - "#235"
  - "#237"
  - "#239"
---

# Unbounded queues and awaits at component boundaries

## Problem

Three instances of the same gap:

- **Send side (#61).** Nothing bounded a session's outgoing queue when the network drained it slower than sync cycles filled it.
- **Inbound side (#113).** A session's inbound task chain grew without bound when messages arrived faster than they were delivered.
- **Cross-boundary awaits (#104).** `LandRouter` awaited `LandManager.getOrCreateLand` and `TransportAdapter.performJoin` with no deadline, and the adapter's membership queue awaited `keeper.join` / `keeper.leave` inside the queued operation. One stalled handler or resolver blocked its caller indefinitely and, behind the serial queue, every later operation for that land (head-of-line). The client CLI had no join timeout either, which turned a dropped join error into a 1 h 38 min CI hang.

## Root cause

A serial queue or an `await` across a component boundary inherits the worst case of whatever is behind it. Without a bound, a slow peer turns into memory growth; without a deadline, into a stall that spreads to everything queued behind it.

## Fix

Every boundary now has a bound or a deadline, each with a named env key in `EnvKeys` / `TransportEnvKeys`, a documented default, and a counter:

| Boundary | Bound | Default | On breach |
|---|---|---|---|
| Send backlog (#61) | `WS_SEND_BACKLOG_MAX_BYTES`, `WS_SEND_BACKLOG_MAX_UNWRITABLE_MS` | 8 MiB, 30 s | close 4008; the client reconnects and gets a fresh firstSync |
| Per-land outbound writer (#86) | `OUTBOUND_WRITER_MAX_BYTES` | 64 MiB | the addressed sessions are closed |
| Inbound backlog (#113, #235) | `WS_INBOUND_BACKLOG_MAX_MESSAGES`, `WS_INBOUND_BACKLOG_MAX_BYTES` | 1024 messages, 4 MiB | stop reading the socket (TCP backpressure) until half is delivered; nothing is dropped |
| Resolver group (#237) | `RESOLVER_TIMEOUT_MS` | 5 s | the resolver is cancelled and its result dropped |
| OnInitialize resolvers (#237) | `RESOLVER_INIT_TIMEOUT_MS` | 30 s | initialization fails and the land is torn down |
| Join, end to end (#239) | `JOIN_TIMEOUT_MS` | 12 s, below the CLI's 15 s | `JOIN_DENIED` with the phase, sent as the last frame before the close |

The deadline helper is `raceDeadline` in `Sources/SwiftStateTree/Support/Deadline.swift`. The join budget covers the lookup and the wait for admission; once the keeper's join has started, its resolvers' deadlines bound it instead, because cutting it off mid-turn would break the queue's order.

## Prevention

- For every new queue, ask: what bounds it, and what does the system do at the bound? For every new `await` on another component: what is its deadline, and who hears about a timeout?
- A breach is visible: a close code, an error frame, or a counter. Never a silent drop.
- Pick deadlines so the server answers before the client gives up (the 12 s join budget under the CLI's 15 s).
- Test with a stub that suspends forever: the caller answers within the deadline, the queue moves on, and no state is left half-applied.

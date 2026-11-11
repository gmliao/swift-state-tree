# The WebSocket server's start and stop, and the transport's stop, as state machines (#101)

Status: open. Read on main d1fd4c4f; not built. Decisions 1 and 2 decided (2026-11-11).

## Scope

The issue's host and `LandManager` parts are done (#351, #372; the issue's 2026-11-11 status comment). Left:
- **A. `NIOWebSocketServer`** (`Sources/SwiftStateTreeNIO/NIOWebSocketServer.swift`):
  - `start()` checks `!isRunning` (:368), stores a new `group` (:374), awaits the bind (:501), then sets `serverChannel` and `isRunning` (:502–503).
  - `shutdown()` checks `isRunning` (:564) and clears it only at its end (:587).
  - So: two starts both pass the check (the second replaces `group`; on port 0 both bind, one listener is lost); a shutdown during a start returns at once and the start then publishes a running listener; two shutdowns both run, and the second `shutdownGracefully()` throws.
  - **Found while reading, not in the issue:** a start whose bind fails (a port in use) leaves its `group` stored and running. `isRunning` stays false, so `shutdown()` returns at once and never shuts the group down: its event-loop threads leak.
- **B. `WebSocketTransport`** (`Sources/SwiftStateTreeTransport/WebSocketTransport.swift`):
  - `stop(closingWith:)` (:255) walks `sessionQueues` and awaits each connection's close, then clears the maps (:268–270).
  - `handleConnection` (:408) has no stopping check. A connection accepted during the walk is registered, then its queue is cleared at the end without finishing its stream, cancelling its drain or closing its connection: it stays open and untracked.
  - Reachable from the host too, narrowly: the host stops the transports (step 6) before the server's shutdown fails the upgrades still waiting for their auth. An auth that completes in between calls `handleConnection` on a stopped transport. The group's shutdown then closes the channel, but the queue's drain task stays parked.

Callers: the host is the only caller of the server's `start`/`shutdown` (NIOLandHost.swift:601, :765) and of `stop(closingWith:)` (via `NIOLandServer.stopTransport`, :208). `WebSocketSessionHandler` (:278) is the only caller of `handleConnection`, and it treats every non-`.accepted` result as a rejection (`guard acceptance == .accepted`).

## Design

### A. The server: `Lifecycle`, as the host does

`private var lifecycle = Lifecycle()` replaces `isRunning`.
- **`start()`:** `lifecycle.beginStart { Task { try await self.performStart() } }`.
  - `.run`: await the task, then `finishStart(token, succeeded:)`.
  - `.join`: await the start in flight.
  - `.alreadyRunning`: log and return, as now.
  - `.stopped`: logs a warning and returns without serving (decision 2).
- **`performStart()`** keeps the group attempt-local until the bind succeeds, then stores `group` and `serverChannel` in one segment. If the bind throws, it shuts that group down (`try? await group.shutdownGracefully()`) before rethrowing, and stores nothing. A failed start returns the lifecycle to `.idle` (Lifecycle's rule), so a later start can retry.
- **`shutdown()`:** `lifecycle.beginStop { start in Task { await self.performShutdown(after: start) } }`.
  - `.run`: await, then `finishStop`.
  - `.join`: await the shutdown in flight.
  - `.nothingToStop`: return.
  - `performShutdown` first awaits an in-flight start (a stop during a start runs after it, and tears down what it published), then runs today's steps.
  - **`shutdown()` still throws** `shutdownGracefully()`'s error, to the caller that ran it and to callers that joined it. It is recorded in the actor, since the stop task is `Task<Void, Never>`.
- **`running`** reads `lifecycle.phase == .running`.
- **`stopAccepting()`** is unchanged. The host calls it between its own start and shutdown, under its own `Lifecycle`.

Behaviour changes, to list in the PR:
- A second `start()` during a start waits for it instead of starting a second listener.
- A `shutdown()` during a start waits for the start, then stops what it started.
- A second `shutdown()` waits for the first and doesn't throw "already shut down".
- A failed start shuts its event-loop group down.
- **A `shutdown()` before any `start()` makes the server stopped**, so a later `start()` doesn't serve (Lifecycle's rule; the host has the same). Today that order works. A start after a completed shutdown "works" today too, but on a stopped `stopFence` and a closed `pendingUpgrades`, so every hand-off and every authenticated upgrade is dropped: it was never a usable restart.

### B. The transport: stop detaches first, and rejects new connections while stopping

- **`stop(closingWith:)`**, in its first segment:
  - sets `isStopped = true`;
  - detaches the maps: `let queues = sessionQueues`, then clears `sessionQueues`, `sessionToClientID` and `playerSessions`;
  - finishes each queue's stream, cancels its drain and ends its flush waiters.
  Only then does it await each connection's close. A second `stop()` while the first is closing waits for it (a stored `Task`, single-flight).
- **`handleConnection`** after `isStopped`: closes the connection (with `close`, or the default close) and returns `.rejected(.transportStopped)` (decision 1), without a queue, a client ID or `onConnect`, as a held ID is rejected now.
- **The server's own disconnect callbacks for the closed sessions** arrive after the stop; they find no queue. Today they also find none (the maps are cleared at the end of the stop), so the delegate sees what it sees today. Unchanged, and not in scope.
- **`start()`** stays a log line. A stopped transport isn't restarted anywhere; a start after a stop doesn't clear `isStopped`.

## Decisions

1. **The rejection's case: decided (2026-11-11): a new case.** The maintainer accepts new cases on public enums as a rule. `ConnectionRejection.transportStopped`, documented "The transport was stopped: it accepts no connection." The PR's Public API section lists it as additive, with its source break: a client's exhaustive `switch` over `ConnectionRejection` without `default` stops compiling. In-repo code only compares to `.accepted`. The connection is closed, and the tests check `.rejected(.transportStopped)` and the close.
2. **A start on a stopped server: decided (2026-11-11).** It logs a warning and returns without serving, as `NIOLandHost.start()` does. `running` stays false. No public surface change, and the host is the precedent. Throwing would need a public error type (`LifecycleError` is package).

## Tests (forced interleaving, no timing)

Server: a new `NIOWebSocketServerLifecycleTests` (SwiftStateTreeNIOTests), on port 0. It needs an internal hold-point enum, `NIOWebSocketServerHoldPoint`: `.bound` (after the bind, before the publish), and `.shuttingDownGroup` (before `shutdownGracefully`). There are also two internal test counters, binds and group shutdowns.
- **(a) Two starts:** hold the first at `.bound`; start a second; release. Both return, there was one bind, `running` is true, and a shutdown leaves nothing running.
- **(b) A shutdown during a start:** hold the start at `.bound`; call `shutdown()`; release. Both return, `running` is false, `localAddress` is nil, and the port bound under the hold refuses a connection.
- **(c) Two shutdowns:** hold the first at `.shuttingDownGroup`; call a second; release. Both return without throwing, with one group shutdown.
- **(d) A failed start:**
  - A first server holds a port (port 0, then its bound port); a second server configured for that port throws from `start()`, with one group shutdown and `running` false.
  - Then the first server shuts down, and the second's `start()` succeeds: a failed start leaves the server idle, not stopped.
- **(e) A start after a shutdown** doesn't serve (decision 2): `running` stays false, and there was no bind.

Transport: a new `WebSocketTransportStopTests` (SwiftStateTreeTransportTests), with a mock connection whose `close` waits on a `TestGate`.
- **(f)** Session A is connected. `stop()` is held in A's close. Meanwhile `handleConnection(B)` is rejected, B's connection is closed, and the delegate gets no `onConnect` for B. Release: `stop()` returns, and neither A nor B is held.
- **(g)** After `stop()`, a `handleConnection` is rejected and its connection closed.
- **(h)** Two `stop()`s, the first held in A's close: the second waits for it. Each connection is closed once.

Mutants:
- the server start without the lifecycle check (today's `isRunning` guard): (a), (b);
- the shutdown not single-flight: (c);
- a failed start not shutting its group down: (d);
- `handleConnection` without the stopped check: (f), (g);
- the maps cleared at the end of the stop instead of detached first: (f) (B's queue, registered meanwhile, is cleared unclosed);
- the transport's stop not single-flight: (h).

## Docs

`docs/transport/README.md` (and `.zh-TW.md`), Connections: a connection that arrives while the transport is stopping is rejected. The server's start and stop semantics go in the doc comments; no user doc covers them today.

## Solutions consulted

- `2026-11-05-await-resumes-on-stale-state.md` (check-then-act across the bind, the close walk)
- `2026-11-05-callback-outlives-its-instance-clears-by-key.md` (attempt-local resources, published in one segment)
- `2026-11-05-hold-points-not-timing-in-race-tests.md`

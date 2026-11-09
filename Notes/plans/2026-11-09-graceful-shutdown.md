# Graceful server shutdown (#351)

Status: design, for review before code. Base: `exp/next` at 357e0c32.

## Problem

A deploy or a restart today runs no destroy handlers, saves no record on destroy, and loses the profiler's last window:

- No server installs a SIGINT or SIGTERM handler, so the process ends with the default action. The only signal code is `ProcessSignals.ignoreSIGPIPE`.
- `NIOLandHost.shutdown()` → `LandRealm.shutdown()` → `NIOLandServer.shutdown()`, which only logs. `LandManager.shutdownAllLands()` is never called outside tests and benchmarks.
- `NIOLandHost.run()` keeps alive with `Task.sleep` and, on cancellation, starts `shutdown()` in an unstructured `Task` it never awaits. So `run()` returns, and `main` exits, before the shutdown has done anything.
- `NIOWebSocketServer.shutdown()` closes the listener and then shuts the event loop group down. Open connections are cut without a WebSocket close frame.
- `NIOLandHost` has no `Lifecycle`. Two concurrent `shutdown()` calls (a signal and a cancelled `run()`) both run the middleware `onShutdown` pipeline and the realm shutdown.

## What already works and is reused

- `LandManager.shutdownAllLands()` sets `isShuttingDown` before its first await: creations are rejected from then on (`JoinError.landShuttingDown`), and creations in flight finish or fail first, so every land they publish is shut down too.
- `LandKeeper.forceShutdown()` → `shutdownIfIdle(cause: .forceShutdown)`. Destruction runs once, and a second caller waits for the one in progress (`drainTask`). It runs OnDestroyWhenEmpty, OnFinalize, AfterFinalize (where GameDemo saves its record through `ReevaluationRecordSaver.saveOnShutdown`), then `onLandDestroyed`. That flushes the adapter's outbound writer (bounded), removes the land **by epoch**, logs `destroyed` with its cause, and releases the cycle (#346).
- `LandKeeper.waitUntilDrained()` waits for a destruction in progress.
- `LandDestructionCause.forceShutdown` is already documented as "a server shutdown or a test harness".
- `LandLifecycleLog` writes each line straight to its file (`O_APPEND`, no buffer), so it needs no flush.

Lessons consulted: `2026-11-05-await-resumes-on-stale-state`, `2026-11-05-callback-outlives-its-instance-clears-by-key`, `2026-11-05-hold-points-not-timing-in-race-tests`, `2026-11-06-unbounded-queues-and-awaits-at-boundaries`, `2026-11-09-a-cancelled-task-waits-for-its-cancellation-handler`, `2026-11-07-darwin-pipe-sigpipe-is-process-directed`.

## Design

### 1. Signals: a library helper the servers opt into

`ProcessSignals.shutdownSignals(_ signals: [Int32] = [SIGINT, SIGTERM]) -> AsyncStream<Int32>`:

- For each signal it sets the disposition to `SIG_IGN` and creates a `DispatchSource.makeSignalSource`. Dispatch is available on Darwin and Linux, so there is no `#if os`.
- The stream yields each delivered signal. Like `ignoreSIGPIPE`, it changes process-wide state, so the library never calls it on its own; `main` opts in.
- **A second signal ends the process at once** with `128 + signal`, the shell convention. An operator who presses Ctrl-C twice, or a supervisor that sends SIGTERM twice, is not held up by a hung destroy. The handler for the second signal does only `_exit`, nothing that allocates or takes a lock.

`NIOLandHost.runUntilShutdownSignal(_ signals: [Int32] = [SIGINT, SIGTERM]) async throws`: it starts the host like `run()`, waits for the first signal, then awaits `shutdown()` to the end and returns. DemoServer and GameServer switch to it. `run()` stays for callers that stop the host by cancellation, and it gets two fixes:

- its keep-alive becomes a wait on a continuation, not a sleep loop with `Task.sleep`;
- on cancellation it **awaits** `shutdown()` before returning, rather than starting it in a `Task` it drops.

### 2. Order of the host shutdown

`NIOLandHost.shutdown()` runs once under a `Lifecycle` (`beginStop`). A concurrent call joins the stop in flight, and a call after it returns at once. Steps, each awaited before the next:

1. **Deregister.** Cancel the middleware tasks and run `onShutdown` in reverse order. This is today's first step: a matchmaker or control plane stops sending players here before anything closes.
2. **Stop accepting.** Mark every `LandManager` as shutting down (the same flag `shutdownAllLands` sets, now set in its own step, synchronously), then close the listening channel. A WebSocket upgrade already in flight that reaches a join is rejected with `landShuttingDown`.
3. **Close the sessions** with the close code (decision A) through `WebSocketTransport.closeSession(_:with:)`. It runs the session's leave (`handleDisconnection` → the router's `onDisconnect`) before it closes the connection, so nothing the client sends afterwards reaches the land. That call sends the close frame without waiting for queued frames; whether it should first wait (bounded) for them is a detail for the PR. What happens to the players depends on decision B.
4. **Destroy the lands.** `NIOLandServer.shutdown()` calls `landManager.shutdownAllLands()`. Each land's `forceShutdown` runs the destroy handlers, the save on destroy, `onLandDestroyed` and the release. A land already being destroyed (its empty-room timer fired) is joined, not destroyed twice.
5. **Stop the transports.** `WebSocketTransport.stop()` for anything left, then `NIOWebSocketServer.shutdown()` shuts the event loop group down.
6. **Flush the diagnostics.** `TransportProfilingActor` writes one last, partial window (new `flushFinalWindow()`, which also marks the line `"final": true` with its real length, so a reader can tell it from a full window). The ticker is left alone, because the actor is process-wide and a test process runs several hosts.
7. Log one summary line: lands destroyed, lands abandoned, sessions closed, elapsed time.

### 3. A bound on the whole shutdown

`NIOLandHostConfiguration.shutdownTimeout: Duration`, default 10 s. That fits inside the usual supervisor grace periods (Kubernetes 30 s, systemd 90 s, `docker stop` 10 s). Set it to `docker stop -t` minus one second where that's the supervisor. The deadline covers steps 3 and 4 together. Steps 1, 2, 5 and 6 are short and keep their own bounds: middleware calls as today, and the flush is a local write.

A land whose destroy is still running at the deadline is **abandoned, not cancelled**. A destroy handler is user code mid-await, and cancelling it would leave its state half written. Shutdown:

- stops waiting for that land, logs it (land ID, the handler it is in, if known) and counts it in the summary;
- goes on to steps 5 and 6. The process then exits with the hung handler still suspended. Its record is not saved and its lifecycle log has no `destroyed` line. The summary line says so.

The bounded wait must not be a task group: a group waits for every child at its end, even a cancelled one, and `drainTask.value` ignores cancellation. So each land's wait runs in its own unstructured task. One continuation is resumed by the first of "all lands done" or the deadline (a `safeTaskSleep`), under a lock, once. That is the shape `ResolverDeadline` already uses. In tests the deadline is a gate the test fires, not a clock (§5).

### 4. Reentrancy

- The phase change is `Lifecycle`'s, made synchronously before the first await. A signal and a cancelled `run()` that race both reach `beginStop`; one runs and the other joins.
- "Stop accepting" is a flag read in the same synchronous segment as the act it guards: the existing `isShuttingDown` check before a creation, and the keeper's `isDraining` before a join. There is no check-then-await-then-act.
- Shutdown removes no land by key. The lands remove themselves through their own `onLandDestroyed` callback, by epoch. An abandoned land's callback may run later, after the summary, or never. Either is harmless, because it removes only its own epoch.
- The per-land waiters capture the keeper, not the `LandID`, and they write only to the shutdown's own collector. A waiter that finishes after the deadline only finds the continuation already resumed.

### 5. Tests (holds, not timing)

All of these go in a new `GracefulShutdownTests` in `SwiftStateTreeNIOTests` (host level), with keeper-level ones in `SwiftStateTreeTransportTests`:

1. **A destroy in progress when shutdown starts.** Empty a land so its empty-room timer starts the destruction, and hold the keeper at `LandKeeperHoldPoint.drainStart`. Start the host shutdown and observe it waiting: its step-4 waiter is registered, and that is a counter, not a sleep. Release the hold. OnFinalize ran once, the lifecycle log has one `destroyed` line with cause `emptyTimeout`, and shutdown returned.
2. **A destroy that hangs.** OnFinalize's resolver blocks on a `TestGate` that is never opened. Shutdown runs with an injected deadline gate, and the test fires it. Shutdown returns, the summary counts 1 abandoned, and the profiler wrote its final window. Then the gate opens: the late `onLandDestroyed` removes only its own epoch, and a new land created under the same ID in the meantime is kept.
3. **Concurrent shutdowns.** Hold step 1 in a middleware's `onShutdown` and call `shutdown()` twice. `onShutdown` ran once, and both calls return after the release.
4. **A join during shutdown.** Hold right after step 2 and send a join. It is rejected with `landShuttingDown`, and no land is created.
5. **Sessions closed with the code**, and the order that decision B gives (for B2, OnLeave for every player before OnFinalize), using a recording transport.
6. **`run()` cancelled** awaits the shutdown: the host task's value arrives only after OnFinalize ran, which is observed through a hold, not a delay.
7. **Signals.** `shutdownSignals([SIGUSR2])` plus `raise(SIGUSR2)` yields `SIGUSR2`. Only `SIGUSR2` is used, so the test runner never sees SIGINT or SIGTERM. The second-signal `_exit` is not run in-process. It is covered by a test that launches the built GameServer as a subprocess, sends SIGTERM, and checks that it exits 0 after the shutdown summary line and that a `.sstr` was written for the land a client had joined.

## Decisions for the maintainer

**A. Which close code the sessions get.**

- **A1: 1001 Going Away (recommended).** This is the standard code for "server going down" (RFC 6455 §7.4.1). Browsers and every WebSocket client know it. The SDK already reports it through `onDisconnect` (`runtime-pending-requests.test.ts` closes with 1001), and no client auto-rejoins on it today.
- A2: a new application code, 4013 `serverShutdown`. It is unambiguous next to a proxy's own 1001, but it's one more code for every client to learn, for no behavior that differs today.

**B. Drain or cut the players.**

- B1, cut: close the sessions and call `forceShutdown` right away. That is `players.removeAll()` with **no OnLeave**, and the destroy handlers run. It is the fastest, and it is today's harness behavior. But a land that saves player progress in OnLeave loses it on every deploy.
- **B2, drain the leaves, then cut (recommended).** Close the sessions (step 3). Each disconnect takes the normal leave path, so OnLeave and its resolvers run and the leave is in the record. Then wait for the lands to empty, within the deadline, and step 4 destroys them. A land that empties before step 4 is joined there. Whatever has not left by the deadline is cut as in B1. This costs one leave per player and keeps the OnLeave contract a game author already relies on.
- B3: wait for the players to leave on their own (stop accepting, keep playing) up to a long grace period, then B2. It suits matches that must finish, but a deploy then takes as long as a match. That is better left as an opt-in later than as the default.

**C. The default `shutdownTimeout`.** 10 s is recommended (see §3). Any value works with the design.

## Public API (all additive and source compatible)

- `ProcessSignals.shutdownSignals(_:) -> AsyncStream<Int32>`
- `NIOLandHost.runUntilShutdownSignal(_:)`
- `NIOLandHostConfiguration.shutdownTimeout: Duration` (with a default, so existing initializers keep compiling)
- `TransportProfilingActor.flushFinalWindow()`
- With A2 only: `SessionClose.Code.serverShutdown = 4013`.

No new `LandDestructionCause` case: adding a case to a public enum breaks exhaustive switches in client code, and `.forceShutdown` already covers a server shutdown. The behavior changes of `run()` (it awaits the shutdown) and `NIOLandServer.shutdown()` (it destroys the lands) are fixes of what their docs already promise.

## Out of scope

Saving or migrating live lands across a restart, and B3's long drain. The firstSync retry bound (#357) is out of scope too.

## Steps (one PR to `exp/next`)

1. Tests 1–6, red.
2. `Lifecycle` in `NIOLandHost`, the step order, the bounded wait, and `NIOLandServer.shutdown()`.
3. The signal helper, `runUntilShutdownSignal`, the profiler's final window, and test 7.
4. DemoServer and GameServer switch to `runUntilShutdownSignal`, in their own commit. Update `docs/` (hosting, both languages), and update #351's table if a consumer's reading changes.

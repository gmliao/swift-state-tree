# Graceful server shutdown (#351)

Status: design revision 3 (with the third review's shoulds folded in), ready to code once the maintainer decides A, B and C. Base: `exp/next` at 357e0c32.

Revision 2 fixes these review findings:
- the leaves are awaited, not assumed;
- joins to existing lands are fenced;
- every step is bounded and runs past errors;
- abandoned lands are detached before the event loops stop;
- the final profile window moves to the process-level entry;
- the signal setup is reordered;
- the integration test moves to its own target;
- `Lifecycle` covers the start;
- the per-land leave queue is bounded as a whole.

Revision 3 fixes these review findings:
- the signals use a `sigaction` handler with a self-pipe, not Dispatch sources (libdispatch on Linux installs its own handler, which `SIG_IGN` would replace);
- a stop fence sits at the connection layer, under the hop to the event loop, replacing the adapter transport swap;
- steps 1 and 3 get sub-budgets and the destroys get a reserved floor;
- the shutdown leave uses the existing `closeSession`;
- the exec inheritance is covered;
- the in-process signal test uses a process-directed `kill`.

## Problem

A deploy or a restart today runs no destroy handlers, saves no record on destroy, and loses the profiler's last window:

- **No signal handling.** No server installs a SIGINT or SIGTERM handler, so the process ends with the default action. The only signal code is `ProcessSignals.ignoreSIGPIPE`.
- **The shutdown path does nothing.** `NIOLandHost.shutdown()` → `LandRealm.shutdown()` → `NIOLandServer.shutdown()`, which only logs. `LandManager.shutdownAllLands()` is never called outside tests and benchmarks.
- **`run()` returns early.** `NIOLandHost.run()` keeps alive with `Task.sleep`. On cancellation it starts `shutdown()` in an unstructured `Task` that it never awaits, so `run()` returns, and `main` exits, before the shutdown has done anything.
- **Connections are cut.** `NIOWebSocketServer.shutdown()` closes the listener and then shuts the event loop group down. Open connections are cut without a WebSocket close frame.
- **Shutdown can run twice.** `NIOLandHost` has no `Lifecycle`. Two concurrent `shutdown()` calls, such as a signal and a cancelled `run()`, both run the middleware pipeline and the realm shutdown.
- **Step 1 is unbounded and stops at the first error.** The middleware step awaits each cancelled task and each `onShutdown` with no bound. A throwing `onShutdown` skips everything after it.

## What already works and is reused

- **`LandManager.shutdownAllLands()`** sets `isShuttingDown` before its first await. New creations are rejected from then on (`JoinError.landShuttingDown`). Creations already in flight finish or fail first, so every land they publish is shut down too.
- **`LandKeeper.forceShutdown()`** calls `shutdownIfIdle(cause: .forceShutdown)`:
  - Destruction runs once; a second caller waits for the one in progress (`drainTask`).
  - It runs OnDestroyWhenEmpty, OnFinalize and AfterFinalize. GameDemo saves its record in AfterFinalize, through `ReevaluationRecordSaver.saveOnShutdown`.
  - Then `onLandDestroyed` runs. It flushes the adapter's outbound writer (bounded), removes the land **by epoch**, logs `destroyed` with its cause, and releases the cycle (#346).
- **`LandDestructionCause.forceShutdown`** is already documented as "a server shutdown or a test harness".
- **The adapter's `onDisconnect`** awaits `enqueueMembership`. It returns once the queued leave has run, OnLeave and its resolvers included, or was rejected.
- **The router's `onDisconnect`** ends a join attempt still on its way (`current.end.markEnded()`, #242). An admission that reaches the adapter's queue after the leave is refused. A leave and a late join of the same session therefore can't apply in the wrong order.
- **`LandLifecycleLog`** writes each line straight to its file (`O_APPEND`, no buffer), so it needs no flush.

Lessons consulted:
- `2026-11-05-await-resumes-on-stale-state`
- `2026-11-05-callback-outlives-its-instance-clears-by-key`
- `2026-11-05-hold-points-not-timing-in-race-tests`
- `2026-11-06-unbounded-queues-and-awaits-at-boundaries`
- `2026-11-09-a-cancelled-task-waits-for-its-cancellation-handler`
- `2026-11-07-darwin-pipe-sigpipe-is-process-directed`

## Design

### 1. Signals: a library helper the servers opt into

`ProcessSignals.shutdownSignals(_ signals: [Int32] = [SIGINT, SIGTERM]) -> AsyncStream<Int32>`:

- **A `sigaction` handler and a self-pipe, not Dispatch sources.** Dispatch sources behave differently per platform. On Linux (swift-corelibs-libdispatch), registering a source installs dispatch's own `sigaction` handler, which a later `SIG_IGN` would replace. On Darwin, kqueue needs the signal ignored. Rather than an `#if os` around two setups, the helper:
  1. creates a pipe (both ends `O_CLOEXEC`, the write end `O_NONBLOCK`);
  2. stores the write end in a process-wide `nonisolated(unsafe)` `Int32`, set before any handler is installed;
  3. installs, with `sigaction`, a `@convention(c)` handler that does only `write(fd, &byte, 1)`. That is async-signal-safe: no allocation, no lock, no Swift runtime call.

  The handler is installed with `SA_RESTART`, so a delivery doesn't interrupt another thread's syscall with `EINTR`. It saves and restores `errno` around its `write`, because a signal can land between another thread's failing call and that thread's read of `errno`. A `write` that fails with `EAGAIN` (the pipe is full) is dropped: the pipe already holds a byte the reader hasn't consumed, so the shutdown still starts, and the escalation needs only a second byte, which the full pipe already holds.

  The handler is in place when `sigaction` returns, so there is no readiness gap. The setup is the same `sigaction` call on Glibc, Musl and Darwin (only the imports differ, as in `ignoreSIGPIPE`).
- **A reader thread of its own.** A dedicated `Thread` blocks in `read` on the pipe. Neither a busy cooperative pool nor a busy dispatch queue can delay it.
- **Lifetime.** The pipe, the handler and the thread live for the life of the process. Calling the helper a second time returns a new stream fed by the same reader.
- **The second signal ends the process.** The reader thread holds one escalation count, shared by every signal in the set. The first delivery yields to the stream. The second, whether SIGINT after SIGTERM or the same signal again, calls `_exit(128 + signal)`, the shell convention. An operator who presses Ctrl-C twice, or a supervisor that sends SIGTERM twice, is not held up by a hung destroy, because the reader thread doesn't depend on the stuck work.
- **Child processes.** A handler, unlike `SIG_IGN`, is reset to the default action across `exec`. A child the server spawns therefore sees SIGINT and SIGTERM normally. (The SIGPIPE rule in `ignoreSIGPIPE`'s doc is unchanged.)
- **Opt-in.** Like `ignoreSIGPIPE`, this changes process-wide state, so the library never calls it on its own; `main` opts in.

`NIOLandHost.runUntilShutdownSignal(_ signals: [Int32] = [SIGINT, SIGTERM]) async throws` is the process-level entry. It:
1. starts the host;
2. waits for the first signal;
3. awaits `shutdown()` to the end;
4. writes the profiler's final window (§2, step 7);
5. returns.

DemoServer and GameServer switch to it.

### 2. Order of the host shutdown

**Lifecycle.** `NIOLandHost` gets a `Lifecycle` that covers both start and stop:
- **Start.** `run()` and `runUntilShutdownSignal` call `start()`. That runs `beginStart` with a start task that binds the listener and returns. The start task is not `run()` itself, so a stop never waits on `run()`.
- **Stop.** `shutdown()` runs `beginStop`:
  - during a start, it runs after that start;
  - from `.idle`, it marks the host stopped, so a later `start()` throws `LifecycleError.stopped`;
  - a concurrent call joins the stop in flight;
  - a call after the stop returns at once.
- **Waking `run()`.** `run()` waits on a continuation registered in the same synchronous segment as a check that the phase is not `.stopping` or `.stopped`. A stop resumes it. On cancellation, `run()` calls `shutdown()` and awaits it; it no longer drops it in a `Task`. An external `shutdown()` therefore wakes `run()`, and a cancelled `run()` returns only after the shutdown finished.

**Errors.** Every step runs even if an earlier one failed or ran out of time. Errors and timeouts are collected, logged in the summary, and `shutdown()` returns normally. It stays `throws` for source compatibility and throws only for a stop that never started. The stop task is `Task<Void, Never>`, as `Lifecycle` requires.

**One deadline.** `shutdownTimeout`, measured from the start of step 1, covers steps 1 to 4. Steps 5 to 7 run after it, with short fixed bounds of their own. Steps, each awaited, or abandoned at the deadline (§3), before the next:

1. **Deregister.** Cancel the middleware tasks and run `onShutdown` in reverse order. A matchmaker or control plane stops sending players here before anything closes. Each wait is a bounded wait (§3), so a stuck heartbeat or `onShutdown` is abandoned at the deadline.
2. **Stop accepting.** One synchronous segment per land server sets the router's `isShuttingDown` flag and the manager's existing flag, which fences creations. Then the listener is closed. The router's flag fences:
   - **joins to existing lands.** The check sits in the join path, in the same synchronous segment that binds the session to its land (`sessionToBoundLandID[sessionID] = landID`, after the last await of the lookup). A join that finds the flag set gets `landShuttingDown` and no binding. A join that bound before the flag is one of the bound sessions step 3 snapshots.
   - **new connections.** `onConnect` with the flag set records nothing and closes the connection at once with the close code (decision A). That covers an upgrade in flight, and an accepted connection whose auth or handler installation finishes late.
3. **Close the sessions and await their leaves.** A new shutdown-path router call takes one snapshot of every session it holds, connected-but-unjoined ones included. For each session:
   - it runs the same cleanup as `onDisconnect`, which also ends a join attempt still on its way;
   - for a bound session, it **awaits** `container.transportAdapter.onDisconnect(...)` instead of spawning it, so it returns when the leave has run (applied or rejected);
   - it closes the connection through the existing `closeSession(_:with:)`. That runs the transport's `handleDisconnection`, which calls the router's `onDisconnect` once more. By then the router's cleanup has removed the session, so the call finds no binding and does nothing. No new `Transport` requirement is needed.
   - the close carries a short `closeGrace` (`SessionClose.closeGrace`, from #361). The handler keeps the channel open briefly after writing the 1001 frame, so a client still sending gets the close frame instead of an RST. The grace runs inside step 3's budget: the closes are issued concurrently, and step 3 ends by its cap whether or not every grace has finished. The destroy floor is never used for it. If #361 hasn't landed on `exp/next` when this PR starts, the PR merges it in first.

   Leaves of different lands run concurrently, and each land's leaves run in order through its membership queue. Step 3 is done when every awaited leave returned, or at the deadline (§3).
4. **Destroy the lands.** `NIOLandServer.shutdown()` calls `landManager.shutdownAllLands()`:
   - each land's `forceShutdown` runs the destroy handlers, the save on destroy, `onLandDestroyed` and the release;
   - players without a session (bots, players the server holds itself) are still in the land here and are removed by `forceShutdown`, as today;
   - a land already being destroyed (its empty-room timer fired) is joined, not destroyed twice.
5. **End the abandoned lands' sessions.** Each land whose destroy did not finish by the deadline ends its session tickets, so its sync and its outbound writer stop issuing frames. This is a courtesy that cuts the late work short and is counted. It is not the guarantee; step 6's fence is.
6. **Stop the transports, behind a fence.** `NIOWebSocketServer` first stops its fence and waits for the submits in flight (§3), then `WebSocketTransport.stop()` handles anything left, then `shutdownGracefully` shuts the event loop group down.
7. **Summary, and the final profile window (process-level entry only).** One summary line covers:
   - lands destroyed and lands abandoned;
   - sessions closed;
   - leaves applied and leaves cut;
   - errors;
   - elapsed time.

   `runUntilShutdownSignal`, and not `shutdown()`, then writes the profiler's last, partial window (§6). `shutdown()` doesn't, because the profiler is process-wide and a process (a test run) can hold several hosts.

### 3. The bound, and what is abandoned or cut

**Default and budgets.** `NIOLandHostConfiguration.shutdownTimeout: Duration`, default 8 s (decision C). It ends before `docker stop`'s default 10 s SIGKILL, with room for steps 5 to 7. Under another supervisor, set it a second or two below that supervisor's grace period: Kubernetes 30 s, systemd 90 s.

So that a stuck control-plane call can't cost every land its save, the total is split:
- **Steps 1 and 2 (deregister, stop accepting):** together at most a quarter of the total, at most 2 s (2 s at the default). Step 2 runs in what step 1 leaves, with a fixed minimum of 250 ms for setting the flags and closing the listener.
- **Step 4 (destroy):** a reserved floor of half the total (4 s at the default). Its own deadline is the total's end or the floor measured from the start of step 4, whichever is later. Step 3 is capped at the total minus the floor, so step 4 starts by then at the latest, and its deadline is then the total's end. With step 2 inside step 1's budget, nothing runs past the total except scheduler slack.
- **Step 3 (leaves):** what is left, up to the total minus the floor. Time steps 1 and 2 didn't use goes to step 3.

The derived budgets are internal. Only `shutdownTimeout` is configuration. At the default, the worst case is 2 s + 2 s + 4 s = 8 s.

**Bounded wait.** Every wait in steps 1 to 4 uses the same shape:
- the work runs in its own unstructured task;
- one continuation is resumed by the first of "done" or the deadline (a `safeTaskSleep`), under a lock, once;
- a late finisher only finds it already resumed. This is the shape `ResolverDeadline` uses.

It is not a task group: a group waits for every child at its end, even a cancelled one. `drainTask.value` and a membership-queue leave ignore cancellation. In tests the deadline is a gate the test opens, not a clock (§5).

**Leaves at the deadline: a land-level cut.** Each land runs its leaves in order on one membership queue, with OnLeave's resolvers awaited under `RESOLVER_TIMEOUT_MS` (5 s by default, unbounded at 0). A land with N players whose resolvers are slow would take N × that timeout. So the per-land drain is bounded by `shutdownTimeout` as a whole, never by the count of leaves. At the deadline, step 4 calls `forceShutdown` on every land, whatever its queue still holds:
- `isDraining` is set in that segment, so each queued leave that runs afterwards is rejected and its OnLeave doesn't run;
- `players.removeAll()` removes those players, as in B1;
- the summary counts these as "leaves cut" per land, and the log line names each land with a cut and how many leaves it had queued;
- the record of such a land has no leave for those players. Its last entries are the destroy handlers', which a replay reads as the end of the land.

**A destroy at the deadline: abandoned, not cancelled.** A destroy handler is user code mid-await; cancelling it would leave its state half written. Shutdown stops waiting for that land and logs it: the land ID, and the handler it is in when the keeper reports one. The abandoned handler stays suspended, and the process exits with it. Its record is not saved, its lifecycle log has no `destroyed` line, and the summary line says so.

**The stop fence (the guarantee that late work never reaches a shut-down event loop).** Work that escaped before the deadline holds its own reference to a transport or a connection, and no adapter-level swap can reach it:
- the `OutboundWriter` consumer, with its frames and queued closes;
- the close Tasks: writer overflow, final-frame fallback, admission cancel, supersede, inbound overflow and `closeLaggingSession`;
- a `WebSocketTransport.closeSession` that captured `queue.connection` before it awaited the delegate.

All of them end in `NIOWebSocketConnection.send` or `close`, which hand off to the channel's event loop. So the fence sits there, at the bottom:
- `NIOWebSocketServer` owns one `StopFence`, internal to the NIO module, and hands it to every connection it creates.
- `send`, `close()` and `close(with:)` pass through the fence (scheme below) before they submit to the event loop. A stopped fence drops the call and counts it; `send` throws `connectionClosed`, as for a closed handler.
- Step 6 stops the fence, waits for the submits in flight, then shuts the event loop group down.

A call either submits before `stopped` is set, while the loop still runs, or sees `stopped` and drops. There is no check-then-act across threads. The session handler's own work already runs on its loop, so it needs no fence.

**The fence on the send path, without a lock per send.** `send` is the measured path (`ServerLoadTest`, ws-loadtest), so the fence doesn't take a lock there. It uses two sequentially consistent atomics (swift-atomics, already a dependency): `stopped` and `inFlight`.
- **A caller** increments `inFlight`, loads `stopped`, submits to the loop only if it is unset (otherwise drops and counts), then decrements `inFlight`.
- **Step 6** stores `stopped`, then waits until `inFlight` is 0, and only then shuts the event loop group down. Every submitter that saw `stopped` unset has finished its submit by then.

Two rules keep it sound in the code:
- **No suspension point inside the window.** Between the increment and the decrement there is only the synchronous enqueue (`handler.send`, `handler.close`, or `promise.succeed`), never an `await`. Otherwise step 6 would wait on whatever that await waits on.
- **A capped wait.** Step 6's `inFlight == 0` wait is a short yield-and-poll loop with a cap (100 ms). At the cap it logs the count still in flight and goes on, so a descheduled caller can't hold the shutdown.

With sequentially consistent ordering, a caller that loaded `stopped` as unset incremented `inFlight` before step 6 stored `stopped`. Step 6 therefore sees that caller's count and waits for it. That keeps the exact check-then-submit guarantee. The uncontended cost is one atomic increment, one decrement and one load per send, and no lock. The PR names this as a send-path change, and it runs a ServerLoadTest A/B (same toolchain, same host) before the eventual merge from exp/next into main.

**The upgrade's auth, the one path outside the connection.** `NIOWebSocketServer` resolves auth in an unstructured `Task`, then `promise.succeed` → `flatMap { channel.pipeline.addHandler(...) }`, on the channel's loop. An auth that finishes after step 6 would succeed a promise of a shut-down loop. The router's `onConnect` fence comes after the handler is installed, so it can't help. That `Task` goes through the same fence: it enters with `inFlight`, checks `stopped`, and either succeeds the promise or, once stopped, drops the upgrade (the channel is closed by the group shutdown) and counts it.

### 4. Reentrancy

- **Phase changes.** Every phase change is `Lifecycle`'s, made synchronously before the first await. A signal and a cancelled `run()` that race both reach `beginStop`; one runs and the other joins.
- **Fences.** Every fence is a flag read in the same synchronous segment as the act it guards:
  - the router's flag, with the session binding and with `onConnect`;
  - the manager's flag, with a creation;
  - the keeper's `isDraining`, with a keeper join and with a queued leave.

  No path checks, awaits, then acts.
- **Leave and join order.** A join's admission and the session's shutdown leave go through the land's one membership queue. A join attempt still on its way is ended by the leave's cleanup (#242), so it can't apply after the leave.
- **Removal.** Shutdown removes no land by key. The lands remove themselves through their own `onLandDestroyed` callback, by epoch. An abandoned land's callback may run later or never; either is harmless, since it removes only its own epoch from a manager that creates nothing more.
- **Waiters.** The waiters capture the keeper or the adapter, not a `LandID`. They write only to the shutdown's own collector, under its lock.

### 5. Tests (holds and gates, not timing)

Host-level tests go in a new `GracefulShutdownTests` in `SwiftStateTreeNIOTests`; router and adapter ones in `SwiftStateTreeTransportTests`. The deadline is injected as a gate the test opens.

1. **A destroy in progress when shutdown starts.** Empty a land so its empty-room timer starts the destruction, and hold the keeper at `drainStart`. Start the shutdown and observe it waiting; its step-4 waiter count is 1, which is a counter, not a sleep. Release the hold. Then check:
   - OnFinalize ran once;
   - the lifecycle log has one `destroyed` line, with cause `emptyTimeout`;
   - shutdown returned.
2. **The leaves are awaited.** Two players in a land, one OnLeave resolver held on a `TestGate`. Shutdown stays in step 3 (no `forceShutdown` yet, observed through a keeper hold that has not been reached). Open the gate. Both OnLeaves run before OnFinalize, and the summary counts 2 leaves applied.
3. **The leave queue is cut at the deadline.** Same land, first OnLeave held, deadline gate opened while it is held. Then the held OnLeave is released. Check:
   - the second player's OnLeave never runs;
   - `forceShutdown` ran;
   - the summary counts 1 leave cut for that land;
   - shutdown returned without waiting for the second leave.
4. **A destroy that hangs.** OnFinalize's resolver blocks on a `TestGate` that stays closed, and the deadline gate is opened. Check:
   - shutdown returns, and the summary counts 1 abandoned;
   - the land's session tickets ended (step 5).

   Then the gate opens and the late work runs. (The epoch rule, that a late callback removes only its own instance, already has its own `LandManager` tests and is not retested through a stopped manager.)
4b. **The stop fence, across step 6.**
   - A disconnect held at the router's `disconnectEntry` hold point, so `WebSocketTransport.closeSession` has already captured its connection, stays held while the shutdown passes step 6. Released, it closes nothing: the fence drops the close and counts 1.
   - An auth resolver held on a gate across step 6 finishes after it: the upgrade is dropped and counted, and no promise of the shut-down loop is succeeded.
   - A fence unit test runs the same check-then-submit from many threads against a concurrent `stopped` set. It asserts that every call either submitted before the set or was dropped. The group is shut down in that test, and NIO reports no execute on a shut-down loop.
5. **A join or a connection during shutdown.**
   - A join to an *existing* land held at the router's `afterLand` across step 2 is rejected with `landShuttingDown` and gets no binding.
   - A connection that reaches `onConnect` after step 2 is closed at once with the close code.
   - A connected-but-unjoined session is closed in step 3.
6. **Step 1 is bounded and doesn't stop the rest.** One middleware whose `onShutdown` throws, and one that hangs until its step-1 budget gate opens. Then check:
   - steps 2 to 7 run, and the summary lists both middlewares;
   - a land with a player completed its destroy: OnLeave and OnFinalize ran, and the record saver was called. The later steps did more than start.
   - with step 3's gate also opened at once, step 4 still got its floor: its deadline gate is a separate gate, and the destroy completed before it was opened.
7. **Lifecycle.**
   - Two concurrent `shutdown()` calls: `onShutdown` ran once, and both return.
   - A `shutdown()` during start, held at the bind: it runs after the start.
   - A cancelled `run()` returns only after OnFinalize ran (observed through a hold).
   - An external `shutdown()` wakes `run()`.
8. **Signals, in process, on Linux CI and on macOS.** `shutdownSignals([SIGUSR2])` with `kill(getpid(), SIGUSR2)` yields `SIGUSR2`. That is a process-directed signal, like a supervisor's, not the thread-directed `raise`. The test runs after the helper returns, because the handler is installed by then. Only `SIGUSR2` is used, so the test runner never sees SIGINT or SIGTERM. The setup is the production one: no test-only path.
9. **Signals, end to end (subprocess).** A small executable target in the root package, `ShutdownSignalProbe`, has no product, so it adds no public API. It hosts one land whose OnFinalize blocks on a gate the test controls through a FIFO. The test, in its own suite, launches the binary built by the same `swift build`. It sends SIGTERM and waits for the probe to report that it is inside OnFinalize, then:
   - **a second SIGTERM:** the process exits with 143 (128 + 15);
   - **a second run, opening the gate instead:** the process exits 0 after the summary line.

   GameServer's own check lives in `Tools/CLI/test-e2e-game.sh`, which builds the binary it launches: SIGTERM after a client joined, exit 0, the summary line, and a `.sstr` file for that land.

### 6. The final profile window

`TransportProfilingActor.flushFinalWindow()` takes the counters as one last window and writes it with `"final": true` and its real `intervalMs`. It also moves the ticker's window boundary to now, so a line the ticker writes afterwards (another host in the same process) has the right interval. Only `runUntilShutdownSignal` calls it, and only once.

The profile JSONL is a measured output, so this adds a line kind. The ws-loadtest readers (`Examples/GameDemo/ws-loadtest/src/server-sync.ts`, `server-send.ts`) infer windows from timestamps. The PR updates them to leave `final` lines out of window counts and per-window maxima, and to add a final line's counters to the totals. The PR also checks the `deep-research` readers (`cell.py` gates) against a profile with a final line. They read windows inside the run, before the stop, so they are expected to be unaffected; the PR confirms it.

## Decisions for the maintainer

**A. Which close code the sessions get.**

- **A1: 1001 Going Away (recommended).** The standard code for "server going down" (RFC 6455 §7.4.1). Every WebSocket client knows it. The SDK already reports it through `onDisconnect`, and no client auto-rejoins on it today.
- A2: a new application code, 4013 `serverShutdown`. It is unambiguous next to a proxy's own 1001, but it is one more code for every client to learn, and nothing behaves differently because of it today.

**B. Drain or cut the players.**

- B1, cut. Close the sessions and call `forceShutdown` right away: `players.removeAll()` with no OnLeave, then the destroy handlers. The fastest, and today's harness behavior, but a land that saves player progress in OnLeave loses it on every deploy.
- **B2, await the leaves, then cut (recommended).** Step 3 awaits each session's leave through the normal membership queue: OnLeave and its resolvers run, and the leave is in the record. Then step 4 destroys the lands. Whatever is still queued at the deadline is cut per land (§3), and the summary counts it. Each player costs one leave, and the OnLeave contract a game author relies on is kept.
- B3, wait for the players to leave on their own (stop accepting, keep playing) up to a long grace period, then B2. It suits matches that must finish, but a deploy then takes as long as a match. That is better left as an opt-in later.

**C. The default `shutdownTimeout`.** 8 s is recommended: it ends before `docker stop`'s 10 s SIGKILL, leaving time for steps 5 to 7 (§3). 10 s would let SIGKILL arrive before the summary and the final window. Any value works with the design.

## Public API (all additive and source compatible)

- `ProcessSignals.shutdownSignals(_:) -> AsyncStream<Int32>`
- `NIOLandHost.runUntilShutdownSignal(_:)`
- `NIOLandHostConfiguration.shutdownTimeout: Duration`, with a default, so existing initializers keep compiling
- `TransportProfilingActor.flushFinalWindow()`
- With A2 only: `SessionClose.Code.serverShutdown = 4013`.

There is no new `LandDestructionCause` case. Adding a case to a public enum breaks exhaustive switches in client code, and `.forceShutdown` already covers a server shutdown. The router's shutdown call and its flag are internal, and so is the NIO stop fence.

Behavior changes, each a fix of what the docs already promise:
- `run()` awaits the shutdown before it returns;
- `NIOLandServer.shutdown()` destroys the lands;
- `NIOLandHost.shutdown()` runs every step past errors and no longer throws from a middleware;
- `start()` after a stop throws `LifecycleError.stopped`.

## Out of scope

- Saving or migrating live lands across a restart.
- B3's long drain.
- The firstSync retry bound (#357).

## Steps (one PR to `exp/next`)

1. Tests 1–8, red.
2. The host: `Lifecycle` in `NIOLandHost`, the step order and the bounded wait.
3. The fences: the router flag, the join fence, `onConnect`, and the awaited shutdown leaves.
4. The detach of abandoned lands, and `NIOLandServer.shutdown()`.
5. The signal helper, `runUntilShutdownSignal`, `flushFinalWindow`, the ws-loadtest readers, and test 9 with its probe target.
6. In their own commits: DemoServer and GameServer switch to `runUntilShutdownSignal`, `test-e2e-game.sh` gains its check, and `docs/` (hosting, both languages) is updated.

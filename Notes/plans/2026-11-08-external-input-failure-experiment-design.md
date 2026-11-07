# Experiment: external inputs that fail or time out

Status: open. Rev 2 after Review's design check (server-side tick timing, end of run driven by the gauge, exact tag accounting, one process per cell, a 1000 ms framework deadline), design only (no runs).

## Question

A land's resolvers call outside services: a profile store, an inventory service. Under load, while those calls are slow, fail or run past their deadline:

1. Does the land keep its tick rate and serve its other inputs while resolvers are pending?
2. Does each failed or timed-out input leave the state unchanged, while its caller gets an error and every other client sees nothing of it?
3. Does the record hold exactly the applied inputs with their resolver outputs, so that re-evaluation matches the live run without calling the service, also when a resolver ignores cancellation and outlives its deadline?
4. What do failures cost: latency of the inputs that succeed, resolvers still running after their caller gave up, memory?

Each answer is a table over failure rate, service delay against the deadline, and rooms.

## What exists (main 490c7c14)

- **The land.** `ResolverTestLand` (`Examples/GameDemo/Sources/GameContent/ResolverTestLand.swift`) has a 50 ms tick and a `CallServiceAction` whose `ServiceCallResolver` calls a `SimulatedExternalService`.
  - The service draws each call's extra delay and failure deterministically from a seed and the call index. It is configured by `RESOLVER_TEST_DELAY_MS`, `_DELAY_JITTER_MS`, `_FAILURE_RATE`, `_DEADLINE_MS` and `_SEED`, and an action can override each one.
  - An applied action bumps `applied`, sets `lastTag` and `lastResult`, and records `lastTickAdvance`, the ticks that passed while its resolver ran.
- **Two deadlines.**
  - The service's own deadline (`RESOLVER_TEST_DEADLINE_MS`) makes the resolver throw. To the framework that is an ordinary resolver failure.
  - The framework's deadline (`RESOLVER_TIMEOUT_MS`, default 5000; OnInitialize's `RESOLVER_INIT_TIMEOUT_MS`, default 30000) cancels the group and fails it with `ResolverExecutionError.timedOut`.
  - The service sleeps with `safeTaskSleep`, so it stops when cancelled. No resolver in the land ignores cancellation today.
- **What failure does, per phase** (`LandKeeper`):
  - **Action:** the input is never queued, the caller gets an error response, and nothing is recorded. Its sequence number is a gap that replay steps over.
  - **OnJoin:** the join fails, and its entry is removed in the segment where the throw resumes.
  - **OnLeave:** the leave is dropped and counted as `onLeaveDropped`; the player is already removed.
  - **OnInitialize:** the land's initialization fails under `.failLand`, the default (#238).
- **Counters.** `ResolverDeadlineMetrics` counts `timeouts`, `initTimeouts`, `initFailures`, `onLeaveDropped`, and the gauge `abandoned` (groups whose caller stopped waiting while their task still runs). The transport profiler (`TRANSPORT_PROFILE_JSONL_PATH`) writes them per interval.
- **E2E.** `test-e2e-game.sh` runs `scenarios/resolver-test/test-resolver-outcomes.json` (slow success, failure and timeout; ticks advance while a call is pending) in each encoding. It also runs a record and verify of that scenario, with successes and failures mixed: the replay matches without calling the service.
- **Re-evaluation.** `ReevaluationRunner --input <record> --verify` knows the land and compares every sync output scope.
- **Load.** `ws-loadtest scenarios/resolver-test/` (default, smoke) drives `CallServiceAction` with `outcome: rate`. Its `errorCount` counts every error response, so an expected service failure and a real error look the same in it.

## Design

### D1. A cancellation-ignoring mode (Examples change)

`RESOLVER_TEST_IGNORE_CANCELLATION` (default false), for the whole service: cells set it in the environment, and the E2E step runs a server with it on. When it's on, the service waits its full delay without checking cancellation, as a client library with its own blocking timeout would. This is the case `abandoned` exists for, and the one that tests question 3's "outlives its deadline". A resolver that is still running when its deadline passes must not reach the state or the record: the group has already failed, and its output arrives after nobody is waiting for it.

### D2. Outcome counters in the load client (Examples change)

`ws-loadtest` counts each request's first answer once, by outcome (`phaseTotals.actionOutcomes`): `applied`, `failed`, `timedOut`, plus `unmatched` for answers that aren't a request's first. Every failed action reaches the client as `ACTION_HANDLER_ERROR` with the error's description as its message, so the class comes from the message:

- `failed`: `Resolver 'ServiceCallResolver' failed: SimulatedServiceFailure(...)` or `ResolverDeadlineExceeded(...)`;
- `timedOut`: the framework's `Resolvers timed out after ...: ServiceCallResolver`;
- `errorCount`: everything else, with any message, which stays the threshold's input.

The strings are pinned in a fixture that a GameContent test checks against the server, so a changed string fails a test rather than turning injected failures into errors. Structured codes are #304. The request ID is the per-request key: every request sent has one outcome, or is pending at the last phase's end. `errorRate` thresholds then keep their meaning: a failure the run injected is not an error.

*Rejected:* raising `errorRate` per cell. That would hide a real error under the injected ones.

### D2b. Server-side tick timing (Examples change)

Question 1 is about the land's ticks, so they are timed on the server. A `TickProbe` service (a lock-guarded class, registered by `ResolverTest.makeServices`) is noted from the land's Tick handler through `ctx.services`. It keeps, per land, the monotonic time of the previous tick handler start and a histogram of the gaps. Every profiler interval it writes one JSONL line with the merged histogram, its bounds and the tick count.

The probe is outside the state. Re-evaluation registers no probe, so the call is a no-op there and the record and replay don't change; the replay gate covers that.

*Rejected:* the gap between `tickCount` values in the syncs the clients receive. Under load that includes the load client's event loop and socket delays, so it measures the client, not the land.

### D3. Matrix

All cells: release build, GameServer with `ENABLE_REEVALUATION=true`, `messagepack`, 4 players per room, 2 actions per second per player, a 60 s steady phase.

**One server process per cell.** `timeouts`, `onLeaveDropped` and `abandoned` are process-wide, so each cell starts a fresh GameServer, and every counter is read as its change over exactly the steady phase (a snapshot at its start and end, from the profiler lines). The join and leave cells never share a process with the action cells.

**Deadlines.** The framework deadline is 1000 ms in the cells that test it (`RESOLVER_TIMEOUT_MS=1000`, not the 5000 default; the README states it). Elsewhere it stays at 5000, above every delay.

| Axis | Values | Fixed elsewhere |
|---|---|---|
| failure rate | 0, 0.1, 0.5 | delay 200 ms, service deadline 1000, framework deadline 5000 |
| which deadline fires | none (delay 200 ms); the service's (delay 1500 ms, service deadline 1000, framework 5000); the framework's (delay 1500 ms, service deadline off, framework 1000) | failure rate 0 |
| cancellation | cooperative, ignored: separate cells | the framework-deadline cell |
| rooms | 50, 200 | the 0.1 failure-rate cell and the framework-deadline cells |

Delay jitter is 0 except for one 0.1-rate cell with 200 ms of jitter, which spreads completions across ticks. The seed is fixed and recorded. The two deadline cells differ only in which deadline fires. Cooperative and cancellation-ignoring calls never share a measured cell, so one cell's latency, `abandoned` and memory describe one mode; the per-call override is for the E2E scenario only. A baseline cell gives the tick and latency reference: `CallServiceAction` at the same rate with delay 0 and outcome `succeed`, so the resolver runs and returns at once.

Join and leave phases: one cell each, a scenario where 10% of joins hit a failing OnJoin resolver and 10% of leaves a failing OnLeave resolver. The land gains both resolvers under a knob (`RESOLVER_TEST_JOIN_FAILURE_RATE`, `_LEAVE_FAILURE_RATE`, default 0). OnInitialize is out of this matrix, since its policy has unit tests and one failure ends the land.

### D4. Metrics

Metric semantics (one unit of each):

- `tick_gap_p50/p99_ms`: the gap between consecutive tick handler starts of one land on the server's monotonic clock (D2b), over every land and the steady phase. The tick period is 50 ms, so a p99 above that is a late tick.
- `applied`, `failed`, `timed_out`: actions, counted from the client's per-tag outcomes (D2). Every tag a client sent has exactly one outcome, none missing and none twice; `collect.py` refuses a cell otherwise. The load client's response timeout is the framework deadline plus 5 s (at least 6 s here), so the client never files a call as timed out while the server may still apply it. They are checked against the server: `applied` equals each land's `applied`, read from its projection at the end, and timed out equals the growth of `timeouts`. The server has no counter of action resolvers that threw, so `failed` is checked only against the client's own error responses.
- `rtt_ok_p50/p99_ms`: the round trip of the actions that succeeded only, from send to response.
- `tick_advance_p50/p99`: the response's `tickAdvance`, the ticks that passed while a successful call was pending. It should follow the delay and stay flat across failure rates.
- `abandoned_max`: the gauge's peak in the profiler intervals.
- `drain_ms`: from the last action sent until the gauge reads 0. The run's end is driven by the gauge: after the last action the orchestrator polls the profiler until `abandoned` reads 0, with a bound (the longest delay plus 10 s) whose expiry fails the cell. Only then does it freeze and check convergence (D5). A fixed wait would only be a quiet period, not completion.
- `rss_mib_peak`: the server's peak resident memory over the run.
- `replay_verdict`: `ReevaluationRunner --verify` on every room's record (all rooms in the 50-room cells, a seeded sample of 50 in the 200-room cells).
- `recorded_actions`: actions in each record, which must equal the room's `applied`.

### D5. Isolation check

Question 2 asks that other clients see nothing of a failed input. At the end of each run, `ws-loadtest` freezes each checked land through the debug routes (`/admin/lands/:landID/debug/freeze` and `projection`, #83, with `ENABLE_DEBUG_STATE_ROUTES=true`). It then compares every client's reconstructed state (`ConnectionReconstruction`, which the load client already has) with that player's projection, and resumes the land. The load client already does this: `converge-main.ts` (`--control`, `--admin-url`, `--land-type`) freezes, projects and compares the lands of clients run with `--reconstruct --control-socket`. The cells run it with `--land-type resolver-test` after the gauge reaches 0. The check covers all rooms of the 50-room cells and a seeded sample in the others. A failed action that leaked into the state would show as `applied` disagreeing with the client tags, and a convergence mismatch as a difference.

A final check is enough. A failed action is never queued, so the only path into the state is a late output of an abandoned resolver, and it would arrive before the gauge returns to 0, which comes before the freeze.

## Gates (a cell is refused if any fails)

- `errorCount` 0 and disconnects 0 in every cell (D2's split makes this hold under injected failures).
- `applied` (client tags) equals the server's `applied` and `recorded_actions`, room by room.
- `replay_verdict` passed on every verified room.
- Convergence passed on every checked room.
- The gauge reached 0 within its bound. In cooperative cells it is 0 in every interval after the deadline.
- Every request has exactly one outcome (`applied`, `failed`, `timedOut` or `errored`), or is pending at the run's end; `unmatched` 0.
- Only the outcomes the cell injects: `timedOut` 0 outside the framework-deadline cells, and `failed` 0 in the cells with failure rate 0 other than the service-deadline cell. The framework's timeout message is the same for an injected and an overload timeout, so an unexpected one is a failed cell, not an injected failure.
- `rtt_ok_*` from the applied answers only (`phaseTotals.appliedRtt`, or the samples' `outcome`).
- Release build, clean tree, recorded `swift --version`.

Mutation checks before the first run:

1. A resolver whose output, once its deadline passes, is still applied when it arrives (a test-only hook). The `applied` and `recorded_actions` checks must fail.
2. A record that keeps one failed action. `replay_verdict` must fail, or the recorded-actions check must.
3. A client counter that files a real error as expected. A deliberately malformed action in the scenario must still raise `errorCount`.

## Where it lands

- D1, D2, the join and leave knobs and the scenarios: Examples changes on main. They're verified with `./Tools/CLI/test-e2e-game.sh`; `test-resolver-outcomes.json` gets one cancellation-ignored step.
- A topic `deep-research/external-input-failure/` with `run.sh`, `collect.py`, `regenerate.py`, tests and README.
- No `Sources/` change is expected. If mutation 1 needs a hook in the keeper, it's a `package`-level test hook in a core PR of its own, merged before the runs.

## Out of scope

- Retries and circuit breakers. The framework doesn't retry, and a retry policy is the application's. This experiment measures what the framework does with the failure it is given.
- Network impairment between client and server: that experiment has its own plan. Its cells and these don't share a run.
- OnInitialize at load (above).

## Settled in rev 2

1. Final convergence after the gauge reaches 0 is enough (D5).
2. The framework deadline is 1000 ms in its cells (D3).
3. The cancellation modes run as separate cells (D3).

# Experiment: external inputs that fail or time out

Status: open. Rev 1, design only (no runs), for Review.

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

`RESOLVER_TEST_IGNORE_CANCELLATION` (default false), plus a per-call override. When it's on, the service waits its full delay without checking cancellation, as a client library with its own blocking timeout would. This is the case `abandoned` exists for, and the one that tests question 3's "outlives its deadline". A resolver that is still running when its deadline passes must not reach the state or the record: the group has already failed, and its output arrives after nobody is waiting for it.

### D2. Outcome counters in the load client (Examples change)

`ws-loadtest` splits error responses by code:

- `expectedFailures`: the service failure and the resolver timeout, which the scenario asked for;
- `errorCount`: everything else, which stays the threshold's input.

Each action carries a per-client request number in its `tag`, so the run's report can list which tags were applied (from `lastTag` and the response), which failed, and which timed out. `errorRate` thresholds then keep their meaning: a failure the run injected is not an error.

*Rejected:* raising `errorRate` per cell. That would hide a real error under the injected ones.

### D3. Matrix

All cells: release build, GameServer with `ENABLE_REEVALUATION=true`, `messagepack`, 4 players per room, 2 actions per second per player, a 60 s steady phase.

| Axis | Values | Fixed elsewhere |
|---|---|---|
| failure rate | 0, 0.1, 0.5 | delay 200 ms, service deadline 1000, framework deadline 5000 |
| delay against deadline | 200 ms (fits), 1500 ms (service deadline at 1000 throws), 6000 ms with service deadline off (framework deadline at 5000 cancels) | failure rate 0 |
| cancellation | cooperative, ignored | the framework-deadline cell |
| rooms | 50, 200 | the 0.1 failure-rate cell and the framework-deadline cells |

Delay jitter is 0 except for one 0.1-rate cell with 200 ms of jitter, which spreads completions across ticks. The seed is fixed and recorded. A baseline cell gives the tick and latency reference: `CallServiceAction` at the same rate with delay 0 and outcome `succeed`, so the resolver runs and returns at once.

Join and leave phases: one cell each, a scenario where 10% of joins hit a failing OnJoin resolver and 10% of leaves a failing OnLeave resolver. The land gains both resolvers under a knob (`RESOLVER_TEST_JOIN_FAILURE_RATE`, `_LEAVE_FAILURE_RATE`, default 0). OnInitialize is out of this matrix, since its policy has unit tests and one failure ends the land.

### D4. Metrics

Metric semantics (one unit of each):

- `tick_interval_p50/p99_ms`: the gap between consecutive committed ticks of one land, over every land and the steady phase, from `tickCount` in each sync the clients receive, with its arrival time.
- `applied`, `failed`, `timed_out`: actions, counted from the client's per-tag outcomes (D2). They are checked against the server: `applied` equals each land's `applied`, read from its projection at the end, and timed out equals the growth of `timeouts`. The server has no counter of action resolvers that threw, so `failed` is checked only against the client's own error responses.
- `rtt_ok_p50/p99_ms`: the round trip of the actions that succeeded only, from send to response.
- `tick_advance_p50/p99`: the response's `tickAdvance`, the ticks that passed while a successful call was pending. It should follow the delay and stay flat across failure rates.
- `abandoned_max`, `abandoned_end`: the gauge's peak in the profiler intervals and its value 10 s after the last action. In the cancellation-ignored cell, `abandoned_end` returns to 0 once the slow calls finish.
- `rss_mib_peak`: the server's peak resident memory over the run.
- `replay_verdict`: `ReevaluationRunner --verify` on every room's record (all rooms in the 50-room cells, a seeded sample of 50 in the 200-room cells).
- `recorded_actions`: actions in each record, which must equal the room's `applied`.

### D5. Isolation check

Question 2 asks that other clients see nothing of a failed input. At the end of each run, `ws-loadtest` freezes each checked land through the debug routes (`/admin/lands/:landID/debug/freeze` and `projection`, #83, with `ENABLE_DEBUG_STATE_ROUTES=true`). It then compares every client's reconstructed state (`ConnectionReconstruction`, which the load client already has) with that player's projection, and resumes the land. Today only the CLI's `assertConverged` step (#85, `Tools/CLI/src/convergence.ts`) calls these routes. The load client takes that module's freeze, settle and compare logic, which makes this an Examples change in the load client. The check covers all rooms of the 50-room cells and a seeded sample in the others. A failed action that leaked into the state would show as `applied` disagreeing with the client tags, and a convergence mismatch as a difference.

## Gates (a cell is refused if any fails)

- `errorCount` 0 and disconnects 0 in every cell (D2's split makes this hold under injected failures).
- `applied` (client tags) equals the server's `applied` and `recorded_actions`, room by room.
- `replay_verdict` passed on every verified room.
- Convergence passed on every checked room.
- `abandoned_end` is 0 (cooperative cells: 0 at all times after the deadline).
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

## Open questions for Review

1. D5 freezes each land after the run. Is a final convergence check enough for "other clients see nothing", or should the run also check at a mid-run freeze?
2. D3 sets the framework deadline at its 5000 ms default. Is a shorter one, such as 1000, more telling for the cancellation cells? It would make the 6000 ms delay unnecessary and shorten the run.
3. D1's per-call override lets one scenario mix cooperative and ignoring calls. Is that preferable to separate cells?

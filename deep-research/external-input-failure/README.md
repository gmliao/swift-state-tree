# External inputs that fail or time out

Design: [`Notes/plans/2026-11-08-external-input-failure-experiment-design.md`](../../Notes/plans/2026-11-08-external-input-failure-experiment-design.md).

## Question

A land's resolvers call outside services. While those calls are slow, fail or run past their deadline, under load:

1. Does the land keep its tick rate and serve its other inputs while resolvers are pending?
2. Does each failed or timed-out input leave the state unchanged, while its caller gets an error and every other client sees nothing of it?
3. Does the record hold exactly the applied inputs, so that re-evaluation matches the live run without calling the service, also when a resolver ignores cancellation and outlives its deadline?
4. What do failures cost: the ack latency and tick advance of the inputs that succeed, resolvers still running after their caller gave up, memory?

## Environment

The measurement host, release builds of GameServer and ReevaluationRunner; the server and the load client share the host, pinned apart (`SERVER_CPUS` 0-7 and `CLIENT_CPUS` 8-11 by default; run.sh refuses an unpinned run unless `SMOKE=1`, and `regenerate.py` refuses one). Each result records the git commit, `swift --version`, `node --version` and whether the tree was clean, and the Results section opens with them and the build, written by `regenerate.py` from the results' `meta` (`--check` verifies the line); `regenerate.py` refuses results with no commit or from more than one, a debug build, a dirty tree, and a run whose joins weren't in the wire form its server environment gives (the refreeze defaults: messagepack, pathIndex on, fieldMerge on; `deep-research/gameserver_wire.py`). The form comes from the joins ws-loadtest counted (`phaseTotals.stateUpdateFeatures`), or, from a client that didn't count them, the commit's ancestry (`deep-research/wireform.py`).

## Command(s)

```bash
cd deep-research/external-input-failure
REPEAT=1 bash run.sh              # every cell; server on CPUs 0-7, client on 8-11
python3 collect.py
python3 regenerate.py --markdown  # paste under Results; then --check
python3 test_topic.py             # no build needed
```

`DRY_RUN=1 REPEAT=1 bash run.sh` prints every command. A smoke run off the host: `SMOKE=1 SERVER_CPUS= CLIENT_CPUS= CELLS="rate10 join10" ROOMS=2 PRE_S=2 STEADY_S=6 TAIL_S=45 REPEAT=1 RUN_ID=smoke bash run.sh`; `collect.py` skips such a sweep and `regenerate.py` refuses its values.

Each cell is one fresh GameServer process (`cell.py`): `ENABLE_REEVALUATION=true`, `ENABLE_DEBUG_STATE_ROUTES=true`, `TRANSPORT_ENCODING=messagepack`, the transport profiler and the tick probe (`RESOLVER_TEST_TICK_PROBE_PATH`) on, and the cell's environment. The load client (`scripts/run-ws-loadtest.sh --external-server --reconstruct --control-socket --samples-dir`) starts at a fixed `--start-at` and runs a 5 s warm-up, the 60 s steady phase and a 90 s tail that sends nothing. In the tail:

1. the profiler shows no message handled for two intervals (`messagesReceived` 0), and over the load no session queued more than 4 messages (`inboundQueuedMessagesMax`), or the cell fails;
2. the script waits until `abandonedResolvers` reads 0, within the longest call plus 10 s, or the cell fails (sequencing only; the `drain_ms` metric is computed from the data);
3. convergence (`converge-main.js`): every land is frozen, each client's state compared with its player's projection, and the land resumed;
4. the clients' states are read from the control socket, and every land's live record is downloaded.

After the load client exits, each record's actions are counted, and `ReevaluationRunner --verify` replays every record of a 50-room cell and a seeded sample of 50 in a 200-room cell. In the leave cell a second load client instance holds slots 2 and 3 of every room (`--room-slots`) and stops after the steady phase, so its players leave lands the first instance keeps up. This deviates from the design's single client with a shorter tail phase: a land ID embeds the players per room, so a phase with fewer players would join new lands instead of leaving the existing ones.

## Parameter matrix

All cells: 4 players per room, 2 `CallServiceAction` per second per player (0.5 in the deadline cells, below), seed 1. Defaults: delay 200 ms, jitter 0, failure rate 0, service deadline (`RESOLVER_TEST_DEADLINE_MS`) 1000 ms, framework deadline (`RESOLVER_TIMEOUT_MS`) 5000 ms, cancellation cooperative, 50 rooms.

| Cell | Rooms | Changed | Injects |
|---|---:|---|---|
| baseline | 50 | delay 0, outcome `succeed` | – |
| rate0 | 50 | – | – |
| rate10 | 50 | failure rate 0.1 | failed |
| rate50 | 50 | failure rate 0.5 | failed |
| rate10-jitter | 50 | failure rate 0.1, jitter 200 ms | failed |
| rate10-r200 | 200 | failure rate 0.1 | failed |
| service-deadline | 50 | delay 1500 ms | failed |
| framework-deadline | 50 | delay 1500 ms, service deadline 10000, framework deadline 1000 | timedOut |
| framework-deadline-r200 | 200 | as framework-deadline | timedOut |
| framework-deadline-ignored | 50 | as framework-deadline, cancellation ignored | timedOut |
| framework-deadline-ignored-r200 | 200 | as framework-deadline-ignored | timedOut |
| join10 | 50 | 10% of OnJoin checks fail | (joins) |
| leave10 | 50 | 10% of OnLeave checks fail; 2 of 4 players per room leave after the steady phase | (leaves) |

The framework deadline is 1000 ms in its cells, not the 5000 default, so a call ends well inside the load client's 5 s response timeout. Every planned call ends within 1500 ms.

**One serial inbound chain per session.** A session's inputs are handled one at a time: an action whose resolvers are running holds that player's later actions until it is answered, which takes up to `hold_ms` (the delay, the service deadline or the framework deadline, whichever ends first; a call that ignores cancellation keeps running after the framework deadline, but its caller has its answer). A player who offers more than its session serves builds a backlog that keeps the server busy after the sends stop. The deadline cells (service-deadline and every framework-deadline cell) hold an action for up to 1000 ms, so they offer 0.5 actions/s per player. Their measured latencies are then the deadline itself, not queueing. `cells.check` refuses any cell with `actions_per_second × hold_ms ≥ 1000`, and `test_topic.py` shows the former 2/s would be refused.

Metric semantics (one unit of each):

- `tick_gap_*_ms`: the gap between consecutive tick handler starts of one land on the server's monotonic clock, merged over every land, from the tick probe's windows that lie wholly inside the steady phase (1 ms buckets). The period is 50 ms.
- `applied`, `failed`, `timed_out`: actions, by the first answer of each request (`phaseTotals.actionOutcomes`), over the whole run.
- `ack_*_ms`: per applied action of the steady phase (`phaseTotals.appliedRtt`), from the client's send to the server's answer, which a land with a tick handler sends once the action's resolvers finished and the input was queued. The handler applies it at the next tick, at most one tick interval (50 ms) later; this is not the time until the change is visible.
- `tick_advance_*`: per applied action of the steady phase, the ticks that passed while its resolver ran (`lastTickAdvance`), counted on the server by the tick probe (`tickAdvances`), since the action's response doesn't reach the client.
- `abandoned_max`: the peak of the `abandonedResolvers` gauge over the profiler's 1 s intervals.
- `drain_ms`: from the last action sent to the first profiler line after it whose gauge is 0 and stays 0 to the end; its resolution is one profiler interval (±1 s).
- `rss_mb_peak`: the server's peak resident memory, from the load client's system metrics of the server's PID.

## Gates

`collect.py` evaluates every gate per cell and `regenerate.py` refuses any result with a failed one:

- errors 0 (`errorCount` and `errored`), disconnects 0;
- one outcome per request: actions sent = applied + failed + timedOut + errored + pending at the end, `unmatched` 0, and nothing pending at the end;
- only the injected outcomes, and each injected one occurs (`regenerate.py` checks this again from the counts);
- per room, the client's applied answers (from the samples, late answers included) = the land's `applied` (the clients' state, which convergence checked against the projection) = the actions in the land's record;
- every replayed record passes `ReevaluationRunner --verify`; every land converged;
- the client's `timedOut` = the growth of the server's `resolverTimeouts`;
- no backlog: over the load (to the quiet point), no session queued more than 4 messages (`inboundQueuedMessagesMax`, `cells.BACKLOG_BOUND`). A cell within its rate holds the action being handled plus at most one that arrived during it; a full-scale run of every deadline cell peaked at 1. A backlog grows by about one per second per session;
- the gauge read 0 within its bound, settles at 0 after the last send and is 0 at the end (`regenerate.py` checks this again); in a cooperative cell it is 0 for good within the longest call plus one profiler interval plus 250 ms of the last send (during the load an interval samples cancellations in flight, which end promptly, so a task that outlives its deadline shows only after the sends stop);
- per room, the OnJoin checks: the land's `joins` = attempts − expected failures, and the client's injected join failures in that land = expected failures; the OnLeave checks: the land's `leaves` = the client's leaves − expected drops, and the server's `onLeaveDropped` up to the states read = the expected drops. The expected failures come from the seeded draws (`collect.mix`, pinned against the Swift side by a test on each side). Any join failure other than an injected one fails the cell;
- the tick probe's steady windows are contiguous and its write failures don't grow;
- release build, clean tree, recorded Swift version, the cell's definition, rooms and phase lengths, and every cell present in every repeat.

## Results

Provenance, from the results' meta: commit `7a0f3b3b3355ad6c8d8dc74f46dcdb9df1b90347`, clean tree; Swift 6.2.4; Node v24.22.2; build release.

Medians over 1 repeat(s) (1). Every cell passed every gate (errors and disconnects 0, one outcome per request, only the injected outcomes, applied = state = record per room, replay, convergence, no backlog, drain, tick probe contiguous). 4 players per room, 2 actions per second each (0.5 in the deadline cells, whose action holds its session for up to 1000 ms), 60 s steady phase.

### Failure rate (delay 200 ms, service deadline 1000 ms, framework deadline 5000 ms, 50 rooms)

Tick gaps on the server (ms, every land, steady phase; the period is 50 ms); the ack of the applied actions (ms, steady phase: send to the server's answer once the resolver finished and the input was queued; the handler applies it at the next tick, at most one tick interval later); and the ticks that passed while an applied action's resolver ran (server side, steady phase):

| Cell | Tick gap p50 | Tick gap p99 | Tick gap max | Ack p50 | Ack p99 | Tick advance p50 | Tick advance p99 |
|---|---:|---:|---:|---:|---:|---:|---:|
| baseline (delay 0, always succeeds) | 49 | 50 | 50.4 | 0.9 | 2.0 | 0 | 0 |
| rate 0 | 49 | 50 | 50.3 | 200.9 | 201.9 | 4 | 4 |
| rate 0.1 | 49 | 50 | 50.2 | 201.0 | 202.0 | 4 | 4 |
| rate 0.5 | 49 | 50 | 50.3 | 200.9 | 202.0 | 4 | 4 |
| rate 0.1, jitter 200 ms | 49 | 50 | 50.3 | 305.6 | 398.2 | 6 | 8 |

Outcomes (whole run), resolvers left running (the drain, from the last send to the gauge at 0 for good, has the profiler's 1 s resolution), and the server's memory:

| Cell | Applied | Failed | Timed out | Abandoned peak | Drain (ms, ±1000) | RSS peak (MB) |
|---|---:|---:|---:|---:|---:|---:|
| baseline (delay 0, always succeeds) | 25,914 | 0 | 0 | 0 | 380 | 74 |
| rate 0 | 25,932 | 0 | 0 | 0 | 364 | 77 |
| rate 0.1 | 24,078 | 1,850 | 0 | 0 | 362 | 77 |
| rate 0.5 | 13,383 | 12,524 | 0 | 0 | 366 | 75 |
| rate 0.1, jitter 200 ms | 24,070 | 1,850 | 0 | 0 | 361 | 79 |

### Which deadline fires (failure rate 0, 50 rooms)

Tick gaps on the server (ms, every land, steady phase; the period is 50 ms); the ack of the applied actions (ms, steady phase: send to the server's answer once the resolver finished and the input was queued; the handler applies it at the next tick, at most one tick interval later); and the ticks that passed while an applied action's resolver ran (server side, steady phase):

| Cell | Tick gap p50 | Tick gap p99 | Tick gap max | Ack p50 | Ack p99 | Tick advance p50 | Tick advance p99 |
|---|---:|---:|---:|---:|---:|---:|---:|
| rate 0 | 49 | 50 | 50.3 | 200.9 | 201.9 | 4 | 4 |
| service deadline (delay 1500, deadline 1000) | 49 | 50 | 50.1 | – | – | – | – |
| framework deadline (delay 1500, 1000 ms), cooperative | 49 | 50 | 50.2 | – | – | – | – |
| framework deadline, cancellation ignored | 49 | 50 | 50.2 | – | – | – | – |

Outcomes (whole run), resolvers left running (the drain, from the last send to the gauge at 0 for good, has the profiler's 1 s resolution), and the server's memory:

| Cell | Applied | Failed | Timed out | Abandoned peak | Drain (ms, ±1000) | RSS peak (MB) |
|---|---:|---:|---:|---:|---:|---:|
| rate 0 | 25,932 | 0 | 0 | 0 | 364 | 77 |
| service deadline (delay 1500, deadline 1000) | 0 | 6,482 | 0 | 0 | 381 | 70 |
| framework deadline (delay 1500, 1000 ms), cooperative | 0 | 0 | 6,469 | 0 | 377 | 71 |
| framework deadline, cancellation ignored | 0 | 0 | 6,490 | 68 | 2,354 | 72 |

### Rooms

Tick gaps on the server (ms, every land, steady phase; the period is 50 ms); the ack of the applied actions (ms, steady phase: send to the server's answer once the resolver finished and the input was queued; the handler applies it at the next tick, at most one tick interval later); and the ticks that passed while an applied action's resolver ran (server side, steady phase):

| Cell | Tick gap p50 | Tick gap p99 | Tick gap max | Ack p50 | Ack p99 | Tick advance p50 | Tick advance p99 |
|---|---:|---:|---:|---:|---:|---:|---:|
| rate 0.1 | 49 | 50 | 50.2 | 201.0 | 202.0 | 4 | 4 |
| rate 0.1, 200 rooms | 49 | 50 | 50.6 | 200.9 | 202.0 | 4 | 4 |
| framework deadline (delay 1500, 1000 ms), cooperative | 49 | 50 | 50.2 | – | – | – | – |
| framework deadline, cooperative, 200 rooms | 49 | 50 | 50.9 | – | – | – | – |
| framework deadline, cancellation ignored | 49 | 50 | 50.2 | – | – | – | – |
| framework deadline, cancellation ignored, 200 rooms | 50 | 50 | 50.3 | – | – | – | – |

Outcomes (whole run), resolvers left running (the drain, from the last send to the gauge at 0 for good, has the profiler's 1 s resolution), and the server's memory:

| Cell | Applied | Failed | Timed out | Abandoned peak | Drain (ms, ±1000) | RSS peak (MB) |
|---|---:|---:|---:|---:|---:|---:|
| rate 0.1 | 24,078 | 1,850 | 0 | 0 | 362 | 77 |
| rate 0.1, 200 rooms | 95,899 | 7,360 | 0 | 0 | 319 | 122 |
| framework deadline (delay 1500, 1000 ms), cooperative | 0 | 0 | 6,469 | 0 | 377 | 71 |
| framework deadline, cooperative, 200 rooms | 0 | 0 | 25,811 | 1 | 346 | 112 |
| framework deadline, cancellation ignored | 0 | 0 | 6,490 | 68 | 2,354 | 72 |
| framework deadline, cancellation ignored, 200 rooms | 0 | 0 | 25,801 | 212 | 2,334 | 118 |

### Join and leave checks (10% fail, 50 rooms)

Tick gaps on the server (ms, every land, steady phase; the period is 50 ms); the ack of the applied actions (ms, steady phase: send to the server's answer once the resolver finished and the input was queued; the handler applies it at the next tick, at most one tick interval later); and the ticks that passed while an applied action's resolver ran (server side, steady phase):

| Cell | Tick gap p50 | Tick gap p99 | Tick gap max | Ack p50 | Ack p99 | Tick advance p50 | Tick advance p99 |
|---|---:|---:|---:|---:|---:|---:|---:|
| rate 0 | 49 | 50 | 50.3 | 200.9 | 201.9 | 4 | 4 |
| 10% of joins fail | 50 | 50 | 50.3 | 200.9 | 202.0 | 4 | 4 |
| 10% of leaves fail (2 of 4 leave per room) | 49 | 50 | 50.3 | 200.9 | 203.6 | 4 | 4 |

Outcomes (whole run), resolvers left running (the drain, from the last send to the gauge at 0 for good, has the profiler's 1 s resolution), and the server's memory:

| Cell | Applied | Failed | Timed out | Abandoned peak | Drain (ms, ±1000) | RSS peak (MB) |
|---|---:|---:|---:|---:|---:|---:|
| rate 0 | 25,932 | 0 | 0 | 0 | 364 | 77 |
| 10% of joins fail | 25,440 | 0 | 0 | 0 | 359 | 77 |
| 10% of leaves fail (2 of 4 leave per room) | 25,906 | 0 | 0 | 0 | 362 | 78 |

Join and leave checks against the seeded draws (counts over the run):

| Cell | Expected join failures | Expected leave failures | Leaves | Leaves dropped (server) |
|---|---:|---:|---:|---:|
| rate 0 | 0 | 0 | 0 | 0 |
| 10% of joins fail | 50 | 0 | 0 | 0 |
| 10% of leaves fail (2 of 4 leave per room) | 0 | 0 | 100 | 0 |

## Conclusion

_Pending the host run._

## Caveats

- Earlier versions of this topic (to ca904c8c) ran the deadline cells at 2 actions/s and took the quiet point from the profiler's `actions`, which counts only successful actions. Every action in those cells times out, so quiet fired as soon as the tail began, while each session still had a backlog of about one queued action per second of load. `framework-deadline-ignored` then failed its drain bound. `framework-deadline` passed its drain gate without testing anything: with cooperative cancellation the gauge is 0 even while the backlog drains. No results from those versions were kept. The fix and the rule are in `Notes/solutions/2026-11-08-quiet-signal-counts-only-successes.md`.
- The tick timing, the drain and the convergence read the server's wall clock (profiler and probe `ts`) against the load client's phase bounds: both run on one host.
- The server has no counter of action resolvers that threw, so `failed` is checked only against the client's own answers and the per-room applied identity.
- Of the design's mutation checks, two ran against the gates on smoke data, by editing a finished cell's outputs: a record that keeps one failed action fails `applied_per_room`; a real error filed as injected fails `timeouts_match_server` when filed as `timedOut`, and `failed_not_injected` when filed as `failed` in a cell that injects no failures. Filed as `failed` in a cell that injects failures, it passes every gate (no server counter, above). The third, a late resolver output applied after its deadline, needs a keeper test hook (#305) and isn't run.
- OnInitialize failures, retries and network impairment are out of scope (design § Out of scope).

# External inputs that fail or time out

Design: [`Notes/plans/2026-11-08-external-input-failure-experiment-design.md`](../../Notes/plans/2026-11-08-external-input-failure-experiment-design.md).

## Question

A land's resolvers call outside services. While those calls are slow, fail or run past their deadline, under load:

1. Does the land keep its tick rate and serve its other inputs while resolvers are pending?
2. Does each failed or timed-out input leave the state unchanged, while its caller gets an error and every other client sees nothing of it?
3. Does the record hold exactly the applied inputs, so that re-evaluation matches the live run without calling the service, also when a resolver ignores cancellation and outlives its deadline?
4. What do failures cost: latency of the inputs that succeed, resolvers still running after their caller gave up, memory?

## Environment

The measurement host, release builds of GameServer and ReevaluationRunner; the server and the load client share the host (`SERVER_CPUS`, `CLIENT_CPUS`). Each result records the git commit, `swift --version`, `node --version` and whether the tree was clean; `regenerate.py` refuses a debug build or a dirty tree.

## Command(s)

```bash
cd deep-research/external-input-failure
REPEAT=1 bash run.sh              # every cell; SERVER_CPUS=... CLIENT_CPUS=... to pin
python3 collect.py
python3 regenerate.py --markdown  # paste under Results; then --check
python3 test_topic.py             # no build needed
```

`DRY_RUN=1 REPEAT=1 bash run.sh` prints every command. A smoke run off the host: `CELLS="rate10 join10" ROOMS=2 PRE_S=2 STEADY_S=6 TAIL_S=45 REPEAT=1 RUN_ID=smoke bash run.sh`; `collect.py` skips such a sweep and `regenerate.py` refuses its values.

Each cell is one fresh GameServer process (`cell.py`): `ENABLE_REEVALUATION=true`, `ENABLE_DEBUG_STATE_ROUTES=true`, `TRANSPORT_ENCODING=messagepack`, the transport profiler and the tick probe (`RESOLVER_TEST_TICK_PROBE_PATH`) on, and the cell's environment. The load client (`scripts/run-ws-loadtest.sh --external-server --reconstruct --control-socket --samples-dir`) starts at a fixed `--start-at` and runs a 5 s warm-up, the 60 s steady phase and a 90 s tail that sends nothing. In the tail:

1. the profiler shows no actions for two intervals;
2. drain: `abandonedResolvers` reads 0 within the longest call plus 10 s, or the cell fails;
3. convergence (`converge-main.js`): every land is frozen, each client's state compared with its player's projection, and the land resumed;
4. the clients' states are read from the control socket, and every land's live record is downloaded.

After the load client exits, each record's actions are counted, and `ReevaluationRunner --verify` replays every record of a 50-room cell and a seeded sample of 50 in a 200-room cell. In the leave cell a second load client instance holds slots 2 and 3 of every room (`--room-slots`) and stops after the steady phase, so its players leave lands the first instance keeps up.

## Parameter matrix

All cells: 4 players per room, 2 `CallServiceAction` per second per player, seed 1. Defaults: delay 200 ms, jitter 0, failure rate 0, service deadline (`RESOLVER_TEST_DEADLINE_MS`) 1000 ms, framework deadline (`RESOLVER_TIMEOUT_MS`) 5000 ms, cancellation cooperative, 50 rooms.

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

Metric semantics (one unit of each):

- `tick_gap_*_ms`: the gap between consecutive tick handler starts of one land on the server's monotonic clock, merged over every land, from the tick probe's windows that lie wholly inside the steady phase (1 ms buckets). The period is 50 ms.
- `applied`, `failed`, `timed_out`: actions, by the first answer of each request (`phaseTotals.actionOutcomes`), over the whole run.
- `rtt_ok_*_ms`: the round trip of the applied actions of the steady phase only (`phaseTotals.appliedRtt`).
- `abandoned_max`: the peak of the `abandonedResolvers` gauge over the profiler's 1 s intervals.
- `drain_ms`: from the last action sent to the first profiler line, after the sends stopped, with the gauge at 0.
- `rss_mb_peak`: the server's peak resident memory, from the load client's system metrics of the server's PID.

## Gates

`collect.py` evaluates every gate per cell and `regenerate.py` refuses any result with a failed one:

- errors 0 (`errorCount` and `errored`), disconnects 0;
- one outcome per request: actions sent = applied + failed + timedOut + errored + pending at the end, `unmatched` 0, and nothing pending at the end;
- only the injected outcomes, and each injected one occurs (`regenerate.py` checks this again from the counts);
- per room, the client's applied answers (from the samples, late answers included) = the land's `applied` (the clients' state, which convergence checked against the projection) = the actions in the land's record;
- every replayed record passes `ReevaluationRunner --verify`; every land converged;
- the client's `timedOut` = the growth of the server's `resolverTimeouts`;
- the gauge read 0 within its bound and is 0 at the end (`regenerate.py` checks this again); in a cooperative cell it is 0 in every interval;
- per room, the OnJoin checks: the land's `joins` = attempts − expected failures, and the client's injected join failures in that land = expected failures; the OnLeave checks: the land's `leaves` = the client's leaves − expected drops, and the server's `onLeaveDropped` = the expected drops. The expected failures come from the seeded draws (`collect.mix`, pinned against the Swift side by a test on each side). Any join failure other than an injected one fails the cell;
- the tick probe's steady windows are contiguous and its write failures don't grow;
- release build, clean tree, recorded Swift version, the cell's definition, rooms and phase lengths, and every cell present in every repeat.

## Results

_No results yet: the measurement host's run fills this section._

## Conclusion

_Pending the host run._

## Caveats

- The tick timing, the drain and the convergence read the server's wall clock (profiler and probe `ts`) against the load client's phase bounds: both run on one host.
- `tick_advance` (the ticks that passed while a call was pending) isn't measured: the samples don't carry the response's `tickAdvance`.
- The server has no counter of action resolvers that threw, so `failed` is checked only against the client's own answers and the per-room applied identity.
- The design's mutation checks (a late output applied after its deadline, a record that keeps a failed action, a real error filed as an injected one) aren't run yet.
- OnInitialize failures, retries and network impairment are out of scope (design § Out of scope).

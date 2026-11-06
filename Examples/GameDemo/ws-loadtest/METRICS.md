# ws-loadtest metric definitions

This file defines each metric ws-loadtest reports: what it measures, where and on which clock, which samples it uses, how they are aggregated, and its known confounds. The README describes how to run the tool and covers the report fields in more depth. Source paths are relative to `Examples/GameDemo/ws-loadtest/`.

## Common rules

- **Clocks.**
  - Client timestamps are `Date.now()` (wall clock, integer ms) in the worker process (`WorkerClient.now`, `src/worker.ts`). They are taken when the `ws` `message` callback runs, not when the packet arrives, so every client-side latency includes the worker's event-loop delay.
  - Server CPU samples carry a monotonic clock (`monoMs`) next to the wall clock.
  - Server profile windows carry the server's wall clock (`ts`). Client and server run on the same host in the reference setup, so their wall clocks agree.
- **The measured window.**
  - Each phase has one window, `[origin + warm-up, origin + duration)`. `origin` is taken once all workers are ready for the phase.
  - Client samples are selected half-open, `[start, end)`. Server CPU intervals and profile windows are counted when they lie within `start ≤ … ≤ end`, both ends included (`src/system-metrics.ts`, `src/server-sync.ts`, `src/server-send.ts`).
  - The warm-up defaults to the phase's connect ramp + 2 s, at most half the phase (`--warmup-seconds` or the scenario's `warmupSeconds` overrides it). The resolved value is in each phase's `measurement` block.
  - The `report` block and the thresholds use only samples inside this window. `phaseTotals` keeps whole-phase counts.
  - Not every pass/fail check is limited to the window; see "Pass/fail".
- **Which timestamp places a sample.** Each metric selects its samples by its own timestamp:
  - RTT and update intervals by receive time;
  - sends and send lag by actual send time;
  - unanswered requests by intended send time;
  - input-to-visible by send time;
  - errors by arrival;
  - server disconnects by close time.
- **Aggregation (client-side distributions: RTT, update interval, input-to-visible, payload bytes).**
  - They pool every sample from every connection and worker into one array (`concatAll`, `src/samples.ts`; `src/run.ts`), then take percentiles of the pooled array.
  - They aren't per-connection percentiles averaged, so busy connections weigh in proportion to their sample count.
  - Percentiles are nearest-rank: the value at index `ceil(p · n) − 1` of the sorted samples (`percentile`, `src/metrics.ts`). An empty array gives 0.
  - Other percentiles are computed differently:
    - `clientLoopDelay`: per-worker histogram percentiles, then the mean and max across workers (see below);
    - the server profiler's `decode_ms`/`handle_ms`/`encode_ms`/`send_ms`: index `min(floor(p · n), n − 1)` of the sorted samples, and absent when there are none (`Sources/SwiftStateTreeTransport/Diagnostics/LatencySampler.swift`).
  - The `measurement.windows` block repeats RTT and update distributions per `--window-ms` (default 1000) window.
- **Server profile windows** are the transport profiler's JSONL lines (`--profile` → `TRANSPORT_PROFILE_JSONL_PATH`, one line per `TRANSPORT_PROFILE_INTERVAL_MS`, default 1000 ms). They hold server-wide deltas summed over every land.
  - A window covers the time from the previous line's `ts` to its own. A phase counts only the windows that lie wholly inside its measured window (`src/server-sync.ts`, `src/server-send.ts`).
  - A window that lacks a section's fields (an older server) is skipped, and the section reads `n/a`.

## Client-side metrics

### RTT (`rtt`)
- **Measures:** from an action's send to the receipt of that action's `actionResponse`, or of an `error` frame carrying the same request ID (`recordRTT`, `src/worker.ts`).
  - With `--send spread` (the default), the start is the intended send time `origin + offset + n · period`.
  - With `--send lockstep`, it is the actual send time: the stamp taken in `sendAction` before the message is encoded and passed to `socket.send`.
- **Includes:**
  - client send queueing and stalls (in spread mode: a late timer shows as larger RTT, not as a missing sample);
  - network and kernel;
  - the wait behind the session's earlier frames in the server's NIO inbound chain, which handles one session's frames in order;
  - the server's two decodes:
    - first in the land router, which reads the message's kind to route it (`LandRouter.onMessage`);
    - then in the transport adapter. With in-turn sync only the adapter shares the keeper's executor, so its decode, not the router's, also waits behind a running tick turn;
  - the action's intake on the land's keeper actor, which waits while the actor runs other work, such as a tick turn;
  - on a land whose action declares resolvers, the resolvers, which run before the action is queued and answered (`LandKeeper.handleActionEnvelope`). Hero Defense's actions have none;
  - the encode of the response, and two output queues:
    - **The land's single ordered outbound stream:** `enqueueOutbound` → `enqueueFrames` (`TransportAdapter+Outbound.swift`). The response waits behind every frame the land has already queued, for all its sessions, including a whole sync cycle's element.
    - **The transport's per-session send queue:** behind that session's earlier frames.

    Because the first queue is per land, this term grows with room size, not only with the session's own traffic. Under load it can be the larger server-side term;
  - the client's event-loop delay before the response callback runs.
- **What the server answers depends on the land** (`LandKeeper.handleActionEnvelope`):
  - **A land with a tick handler (Hero Defense):** the action is queued, and an empty response is returned without waiting for it to run. The handler runs in a later tick turn. RTT doesn't wait for the handler, the tick or a sync. Nothing orders the response against that tick, so the response may reach the client before or after the action runs.
  - **A tickless land:** the response comes after the input turn that applies the action.
- **Not a visibility measure:** in neither case is RTT the time until the action's effect is visible (see input-to-visible).
- **Samples:** answered actions whose response arrives inside the measured window. Unanswered requests are not in the distribution; `measurement.unanswered` counts them by intended send time, with a 5 s late threshold.
- **Units:** ms. The phase report gives p50/p95/p99; max is only in the per-window `measurement.windows` distributions.
- **Confounds:**
  - client CPU saturation and event-loop delay (see `clientCpu`, `clientLoopDelay`);
  - `Date.now()` resolution (1 ms);
  - in lockstep mode, coordinated omission (a stalled client sends nothing, so it records no slow samples).

### Update interval (`update`)
- **Measures:** the inter-arrival time between consecutive state updates at one connection, i.e. the time between handling one sync's state and the next. **It is not a latency**: a server that delivers every update equally late shows the same intervals.
- **Grouping:** one sync is one update. With messagepack, a land with per-player fields sends the merged broadcast frame (opcode 107) and then a per-player frame. A plain state frame within 10 ms (`SYNC_FRAME_GROUP_MS`) after a 107 frame counts as part of that sync. Hero Defense has only broadcast fields, so each of its syncs is one frame.
- **Samples:**
  - intervals whose later update arrives inside the measured window;
  - a connection's first update (its join snapshot) starts no interval.
- **Units:** ms. The phase report gives p50/p95/p99; max is only in `measurement.windows`.
- **Expected value:** the land's sync interval (Hero Defense `StateSync(every: 100ms)`, so about 100 ms) plus client jitter.
- **Confounds:** client event-loop delay adds to individual intervals. Grouping is a timing heuristic: under heavy client load, the two frames of one sync can arrive more than 10 ms apart and count as two updates (`measurement.stateUpdates.syncFrameGrouping`).

### Input-to-visible latency (`measurement.inputToVisible`, #64)
- **Opt-in:** `--input-latency on` (off by default because the scan costs load-client CPU). It needs move events, from `--move-to-rate <n>` or a scenario's `events`.
- **Measures:** from a move event's send to the first state-bearing frame at the same connection that contains the event's point (`src/input-latency.ts`).
  - The send time is the actual one: the stamp taken in `sendEvent` before the message is encoded and passed to `socket.send`.
  - **The match:** the tracker walks the whole decoded frame, a merged 107 frame's event payload included. Any `{ v: { x, y } }` object whose coordinates equal a pending point's counts as a match. There is no check of the player, the field or the path.
  - Hero Defense: `MoveTo { target }` sets `players[id].targetPosition`.
  - visibility-test: `MoveViewer { position }` sets `viewers[id].position`.
  - The server diffs a `Position2` as one value, so the point arrives whole in every encoding.
- **Includes:** client send, network, the event's wait for and run in a keeper turn, the wait for the next sync that carries the change, encode, send, and the client's event-loop delay.
- **Unlike RTT in spread mode,** it is measured from the actual send, not the intended one.
- **Samples:** events sent inside the measured window.
  - `sent` and `seen`;
  - `superseded`: when a connection sends a ninth event while 8 are pending (`INPUT_LATENCY_MAX_PENDING`), the oldest pending entry is evicted and counted here;
  - `timedOut`: pending entries more than 5000 ms old (strictly greater), checked only when the next state-bearing frame arrives at that connection;
  - the `latencyMs` distribution, pooled over connections;
  - events still pending at the phase end aren't counted.
- **Units:** ms. Report fields: p50/p95/p99 and seen / sent.
- **Confounds:**
  - client event-loop delay, and the scan's own client CPU;
  - a false match is any `{ v: { x, y } }` object anywhere in the frame (another player's field, an event payload) with the same fixed-point coordinates as a pending point;
  - `superseded` counts evictions only. It doesn't tell whether the evicted point would have become visible.

### Server CPU (`serverCpu`)
- **Measures:** the GameServer process's CPU time rate. `monitoring/collect-system-metrics.sh` (wrapping `collect-system-metrics.mjs`) samples the server PID about once per second:
  - its cumulative CPU time `cpuSec` (user + system), from `/proc/<pid>/stat` on Linux and `ps -o time=` elsewhere;
  - `monoMs`, `tsMs`, RSS and load.
- **Per sample,** `cpuPct = Δ cpuSec × 1000 × 100 / Δ monoMs` over the interval since the previous sample (`cpuSec` in seconds, `monoMs` in ms). **100 = one core fully busy**, so 360 means 3.6 cores. The first sample is null.
- **Window:** only the samples with `start ≤ tsMs ≤ end`, and the intervals between them.
- **Aggregation:** `meanPct` is time-weighted over those intervals, plus `p95Pct` and `maxPct` of the interval rates.
- **Confounds:**
  - it covers the whole server process (all lands, NIO threads, logging, the profiler when `--profile` is on);
  - the host's other load and the core pinning aren't visible in it.
  - Reports made before `713ffd95` sampled `ps -o %cpu`, which on Linux is CPU time over the process's whole lifetime. Those files have no `cpuSec` and give `serverCpu: null`.

### Load client CPU and event-loop delay (`measurement.clientCpu`, `measurement.clientLoopDelay`)
- **`clientCpu`:**
  - each worker samples `process.cpuUsage()` (user + system) every 500 ms;
  - it reports each worker's share of one core over the measured window (`perWorkerPct` min/mean/max), the orchestrator's (`orchestratorPct`), and `totalPct` (% of one core, all processes).
- **`clientLoopDelay`:**
  - `perf_hooks.monitorEventLoopDelay` (1 ms resolution) per worker, from the measured window's start to the phase end;
  - each worker's p50 and p99 come from its own histogram, minus the 1 ms resolution and floored at 0 (`src/loop-delay.ts`);
  - `p50Ms` and `p99Ms` give the mean and the max of those per-worker values; `maxMs` is the longest single delay of any worker.
- **Use:** they tell whether the load client, not the server, may be adding to RTT, update intervals and input-to-visible latency.

### Sends, errors, disconnects, joins
- **Send lag:** the actual minus the intended send time (spread mode). Late sends are those more than one period late. The achieved send rate is compared with rate × the time-weighted average of joined, open clients.
- **Error rate:** error frames and socket errors received in the window ÷ actions sent in it. Join failures are excluded.
- **Disconnect rate:** closes the client didn't ask for (server-initiated), including those between phases.
- **Join failures** (`connectionLifecycle.joinFailures`): `error`, `rejected`, `closed`, `timeout` (5 s). Any join failure fails the phase unless `--allow-join-failures` is set (see "Pass/fail").
- **Listen queue** (Linux): increases of `ListenOverflows` / `ListenDrops` from `/proc/net/netstat`. The scope is the host or network namespace, so they describe the server only when it shares the client's host or namespace.

## Server-side metrics (profile JSONL, `--profile`)

### Sync cycles and skips (`serverSync`)
The fields come from `TransportProfilerCounters` (`Sources/SwiftStateTreeTransport/Diagnostics/TransportProfilingActor.swift`), incremented in `TransportAdapter`.
- **`syncCycles`:** sync cycles that committed their plan (both sync paths). It is the denominator of the rates below.
- **`syncSkipsBacklog`:** cycles skipped because the outbound writer still held an earlier cycle's element (writer back-pressure).
- **`syncDeferredTurns`:** in-turn sync phases deferred by writer back-pressure. They are a subset of `syncSkipsBacklog`, not a separate cause.
- **`syncSkipsBusy`:** cycles skipped because another cycle was in flight (legacy, not in-turn, path).
- **Report:** totals over the counted windows, the largest single-window value, and the windows counted.

### Sync folds (`syncFolds`, `syncOverdueFolds`)
- **`syncFolds`:**
  - With in-turn sync, when the sync loop fires within `coincidentSyncWindow` (min(5 ms, tick/4, sync/4)) of the next tick deadline, that sync doesn't run its own turn. It folds into that tick turn instead, counted once per tick turn (`LandKeeper.runSync`).
  - The fold is intended: a sync never overtakes a tick due at the same instant.
- **`syncOverdueFolds`:** folds where the tick's deadline had already passed when the sync loop ran. The report gives `overdueFoldsPer1000Syncs = syncOverdueFolds × 1000 / syncCycles` and the windows with at least one overdue fold.
- **Caveat (#232):**
  - A land's tick and sync loops share a phase offset (`LandLoopPhase.offset`, a hash of the land ID modulo the interval), and Hero Defense's sync interval (100 ms) is a multiple of its tick (50 ms). So every sync deadline lies within about a millisecond of a tick deadline.
  - Whether a fold counts as overdue then depends on which loop's task runs first after the shared deadline, so the count is mostly a scheduler race of µs to ms. It doesn't measure tick lateness, and it reads about the same at every load.
  - Until #232 changes the definition, read `syncFolds / syncCycles`. Treat `syncOverdueFolds` as a measure of that race.

### Send backlog (`serverSend`, #61)
- **`sendBufferedBytesMax`:** the largest per-session outbound buffer sampled after a write in the window: bytes NIO still held and the socket hadn't accepted.
- **`sendUnwritableEpisodes`:** sessions that became unwritable (above the 64 KiB high watermark) in the window.
- **`sendUnwritableLongestMs`:** the longest unwritable episode that ended in the window.
- **`sendUnwritableSessions`:** a gauge, the sessions unwritable when the window was taken.
- **`sendBacklogCloses`** (optional, a server with the send backlog bound): sessions closed with code 4008 because the backlog stayed over the bound, 8 MiB or 30 s unwritable by default.
- **`closeFrameTimeouts`** (optional): server closes whose close frame wasn't written within 5 s, so the channel closed without it.
- **Optional counters** read `null` / `n/a` unless every counted window has them.

### Inbound side
The profile has no inbound backlog counter. On the inbound side it reports only `messagesReceived` and `bytesReceived` per window (the counters), and the decode/handle percentiles (1 % sampled). On the client side, the listen-queue counters cover the accept backlog on Linux.

## Pass/fail, thresholds and the sync budget
A phase fails when any of these holds (`src/report/render-html.ts`, `evaluateThresholds` in `src/metrics.ts`):
- a measured-window value exceeds the scenario's thresholds;
- a join failed;
- fewer players than the target are joined at the phase end, or at the measured-window start when the warm-up is longer than the connect ramp. With `--allow-partial-ramp` the joined counts are compared with the connections the phase held (kept or started by the ramp), not with the target;
- a frame the client couldn't decode arrived before the connection began to leave, anywhere in the phase, warm-up and ramp included.

`--allow-join-failures` waives the join checks, but not the decode check.

There is no separate sync-budget field.
- Hero Defense `default.json`: `errorRate` and `disconnectRate` ≤ 0.001, `rttP95` ≤ 100 ms, `rttP99` ≤ 250 ms, `updateP95` ≤ 120 ms, `updateP99` ≤ 250 ms.
- The update thresholds act as the sync budget: the sync interval (100 ms) plus a margin for client jitter. They bound how far update delivery may stretch past the sync interval, not a latency.

## Method changes since February 2026
The February 2026 runs used the client as of `ac00e3a1`. The November method differs as follows (facts and commits only):

| Change | Commit |
|---|---|
| Room layout: `rooms × playersPerRoom` connections join `rooms` lands of `playersPerRoom` players. Before, each connection joined its own land (`--layout per-connection`). Also long-lived workers and a connect ramp. | `5ff91337` (#123) |
| Sends spread over the period per connection; RTT from the intended send time. Before, one timer per worker sent for all its clients, and RTT ran from the actual send. | `0d80e16d` (#126) |
| A phase fails when players fail to join | `d89d176d` (#135) |
| jsonObject state updates counted | `fe81a7e8` |
| Measured-start counters read no earlier than the window | `4863d7a7` |
| Load client CPU per phase; orchestrator CPU and worker event-loop delay | `eadf143c`, `75043e1d` |
| Worker phases end no earlier than the phase end | `09c3616f` |
| Server sync skip, deferral and fold counters | `1d4dc06f` (#177) |
| Server CPU as interval rates of cumulative CPU time. Before, `ps -o %cpu`, a lifetime average on Linux. | `713ffd95` |
| One update per sync, not per frame | `9c14cea5` |
| Join latency per phase | `dd6e0a20` |
| Input-to-visible latency | `68e767f9` |
| Server send backlog counters; backlog closes; close frame timeouts | `6c54b74a` (#217), `a132c4db`, `4e0affe9` |
| The scalability script: `--runs` with a room list refused; skipped room counts after a TIME_WAIT wait fixed; nonzero exit when a run failed or was skipped | `a398f5d5`, `e6f30a74`, `15986f23` |

`--layout per-connection --connect burst --boundary abrupt --send lockstep --warmup-seconds 0` comes closest to the February client. It isn't identical: there is still the warm-up handling and per-metric window selection.

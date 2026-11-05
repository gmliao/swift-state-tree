# WS Load Test (Hero Defense)

This tool runs a **real WebSocket client** load test for the `hero-defense` land using Node.js `ws` clients.
It supports multi-process workers, phased scenarios, and generates **JSON + HTML** reports.

## Quick Start

```bash
cd Examples/GameDemo/ws-loadtest
bash scripts/ensure-deps.sh
npm run build
bash scripts/run-ws-loadtest.sh --scenario scenarios/hero-defense/default.json
```

ws-loadtest depends on the TypeScript SDK through `file:../../../sdk/ts` and imports its built `dist/`, so on a fresh checkout `npm run build` here fails (TS2307 on `@swiftstatetree/sdk/...`) until `sdk/ts` is installed and built. `scripts/ensure-deps.sh` does that: `npm ci` in `sdk/ts` when its `node_modules` is missing or older than its lockfile, `npm run build` there when `dist/` is missing or older than its sources, then `npm ci` here on the same rule. It uses `npm ci` only, so neither `package-lock.json` is rewritten, and does nothing when all are current. `run-ws-loadtest.sh` (and so `run-scalability-test.sh`) runs it and this package's build before starting the server.

Reports are written to:
```
Examples/GameDemo/ws-loadtest/results/
```

## Scalability test (multiple runs)

Run the same scenario multiple times and aggregate pass/fail and metrics (similar to `Examples/GameDemo/scripts/server-loadtest/run-scalability-test.sh`):

```bash
cd Examples/GameDemo/ws-loadtest
bash scripts/run-scalability-test.sh --runs 5 --scenario scenarios/hero-defense/default.json
```

Notes:
- Default mode is **scale-by-rooms** (100 → 300 → 500 → 700). Run it with: `bash scripts/run-scalability-test.sh --scale-by-rooms` (or simply `bash scripts/run-scalability-test.sh`).
- To run the same scenario N times, use: `bash scripts/run-scalability-test.sh --no-scale-by-rooms --runs <N>`.
- To control client-side worker processes, use: `--workers <N>` (default: CPU cores).

Options: `--runs <N>`, `--no-scale-by-rooms`, `--room-counts "N1 N2 N3"` (scale by room count), `--workers <N>`, `--scenario <path>`, `--output-dir <dir>`, `--startup-timeout <s>`, `--delay <s>` (seconds between runs), `--profile` (enable transport profiling). Output is written to `results/scalability-<timestamp>/` with a `summary.json`, per-run logs/reports, and a **summary.html**. The summary report is generated as a **static HTML** (no runtime Vue/JS required): the template is `scripts/scalability_summary_template.html` and `scripts/render-summary-html.js` renders `summary.json` into the final HTML, so you can edit the template and re-run the script to change the report layout.

## CLI

```bash
node dist/cli.js \
  --scenario scenarios/hero-defense/default.json \
  --workers 4 \
  --output-dir results \
  --system-metrics monitoring/system-metrics.json \
  --transport-profile results/transport-profile.jsonl
```

`--transport-profile` reads the server's transport profile (JSONL, one window per line, written when the server runs with `TRANSPORT_PROFILE_JSONL_PATH`; `run-ws-loadtest.sh --profile` sets it and passes the file). The report's `serverSync` block then gives, per phase, the server-wide sync counters over that phase's measured window, the same span as the client metrics (warm-up excluded). Only profile windows wholly inside the measured window count, so the covered span (stated per phase) can be up to one window shorter at each end; the CLI waits for the window that closes the last measured window to be flushed before reading. The counters: committed sync cycles; skips for writer backlog, of which in-turn deferrals; skips for a cycle in flight; sync cycles folded into a tick turn, of which into an overdue tick. A fold counts once per cycle, so overdue folds per 1000 sync cycles is the share of cycles that waited on a late tick, which compares across room counts. For each counter the block gives the total and the max in one window, plus the windows with an overdue fold. The windows are placed by the server's wall clock and the measured window by the client's, so with the server on another host, clock skew between the two shifts which profile windows count; keep both hosts NTP-synced, or treat the covered span's ends as uncertain by the skew. Without a profile, or with one from a server older than these counters, the block is `null` and the HTML says "n/a"; a phase with no profile window inside its measured window says "n/a" too.

## Room layout and connections

- **Layout** (`--layout`, default `rooms`): a phase's `rooms × playersPerRoom` connections join `rooms` lands of `playersPerRoom` players (`<runId>-room-p<playersPerRoom>-<room>`). Whole rooms go to one worker. `--layout per-connection` is the earlier behaviour: one land per connection (`<runId>-<phase>-<worker>-<i>`).
- **Run id**: every land id starts with a new short id per run (`--run-id` to set it), so back-to-back runs on one server never join each other's live or draining lands. `run-scalability-test.sh` restarts the server for every run anyway; the id matters when the CLI runs against a long-lived server.
- **Connect** (`--connect`, default `ramp`): new connections open at about `--connect-rate` per second over all workers (default 1000/s), each jittered inside its slot. `--connect burst` opens them all at once (join-storm tests). A phase whose ramp needs longer than the phase fails the run before it starts. `--allow-partial-ramp` runs it anyway with a warning, and the phase's `connectionLifecycle` then shows `started` and `joinedAtEnd` below `target`.
- **Across phases** (`--boundary`, default `clean`): workers live for the whole run. A connection whose room is also in the next phase stays open; the others are closed with a close frame (code 1000) before the next phase opens new ones. At the end every connection is closed the same way. With the `rooms` layout, phases with the same `playersPerRoom` share lands and connections. `--boundary abrupt` drops those sockets without a close frame instead (the server sees FIN or RST, depending on unread data).
- **Legacy topology**: `--layout per-connection --connect burst` gives the same topology and connect burst as the old tool. Phase boundaries still close cleanly, unlike the old tool's resets, so the boundary load and the first seconds of each phase differ. Add `--boundary abrupt` to drop the sockets at boundaries as the old tool did. The sockets are then dropped when the next phase starts rather than as each worker exits.
- **Report**: `meta.runConfig` records the run id, layout, connect mode and rate, boundary mode, workers, and every phase's rooms, players, connections, lands and ramp time. Each phase has `layout` (lands, players per land) and `connectionLifecycle`: target, started, joined at the end, opened, reused, closed at start, ramp duration, and close counts split by initiator and code, plus the first 200 close records. `disconnectRate` counts only closes the client didn't ask for, including server closes on connections between phases. `meta.shutdownCloses` covers the end of the run.

## Sending and measurement

- **Phase start**: a phase starts in two steps. Every worker first closes the previous phase's surplus connections and gets ready, and only then is the common origin taken. Connects (the ramp) and sends count from that origin. Each phase's `connections.transitionMs` is how long the transition took.
- **Send schedule** (`--send`, default `spread`): each client sends at `origin + offset + n · period` (`period = 1000 / actionsPerSecond` ms). The per-client offset in `[0, period)` comes from a stable hash of the connection, so a land's actions are spread over the tick and sync phase and runs are reproducible. A timer that fires late sends every slot it missed. `--send lockstep` is the earlier behaviour: one timer per worker sends for all of its joined clients at once.
- **RTT origin**: in `spread` mode RTT is measured from the intended send time, so client-side queueing and stalls show up as larger RTT, not as missing samples (no coordinated omission). The report also gives the send lag (actual minus intended), the late sends (more than one period late) and the achieved send rate against the target. The target is the rate × the time-weighted average of joined, open clients over the measured window. In `lockstep` mode RTT is measured from the actual send, as before.
- **Warm-up**: RTT and update samples, errors, server disconnects and sends in the first `warmupSeconds` of each phase are excluded from the phase's `report` and thresholds. `phaseTotals` keeps the whole-phase error, disconnect and send counts, transition included. Set it per phase in the scenario or for all phases with `--warmup-seconds`. The default is the phase's connect ramp + 2 s, at most half the phase. Each phase's `measurement` block gives the resolved warm-up and the excluded sample counts.
- **Joins**: a join fails when the server rejects it (`error`: an error frame, e.g. a full room; `rejected`: a join response with `success: false`), the connection closes before it joined (`closed`), or nothing answers it within 5 s of connecting, or by the phase end if sooner (`timeout`; a late answer doesn't join). Each phase's `connectionLifecycle.joinFailures` counts them over the phase and in the measured window, by reason, and `joinFailureRecords` lists the first ones. The HTML report has a join-failures column and lists each FAIL row's reasons. Join failures are not counted in `errorCount`. A phase **fails**, whatever the scenario's thresholds are, when any join failed, when fewer than `target` connections are joined at the phase end (`measurement.joined.atEnd`), or, when the warm-up is longer than the connect ramp (the default), at the measured-window start (`joined.atMeasuredStart`, which catches joins slow enough to leave part of the window unloaded). With a shorter warm-up (e.g. `--warmup-seconds 0`, or a burst connect without warm-up) that check is skipped and `atMeasuredStartNote` says so. The window-start check needs a margin: a warm-up only slightly longer than the ramp fails it when the ramp overruns or a join's round trip lands after the window start. The default warm-up (ramp + 2 s, at most half the phase) is the safe margin; when setting `--warmup-seconds` yourself, keep at least that much above the ramp, or set it to 0 to skip the check. The time-weighted `joined.average` over the window is reported only. Only joined connections are kept for the next phase: one that didn't join is closed at the transition, and the next phase opens a new connection that joins again. `--allow-join-failures` turns both checks off. With `--allow-partial-ramp` the joined counts are compared with the connections the phase held (kept or started by the ramp) instead of `target`. The resolved flags are in `meta.runConfig`.
- **Update samples**: state updates are recognized in every encoding: jsonObject `{ type: noChange | firstSync | diff }` frames and the opcode arrays (opcodeJsonArray, messagepack, and the merged 107 frame). A phase whose joined clients recorded no update samples in the measured window gets a **warning** in `warnings` and under its PASS/FAIL cell, because its update percentiles are then 0 for lack of data. The warning doesn't fail the phase.
- **Error rate**: error frames and socket errors received in the measured window divided by the actions sent in it (0 when none were sent). Join failures are excluded, so a large action count can't dilute them.
- **One measured window, per-metric keys**: every metric uses the same measured window `[origin + warm-up, origin + duration)`, but each selects its samples by its own timestamp. RTT and update intervals go by completion (receive) time, sends and send lag by actual send time, errors by arrival time, server disconnects by close time, and unanswered requests by intended send time (the RTT origin).
- **Unanswered requests**: `measurement.unanswered` counts the requests still unanswered at the phase end, those of them older than 5 s (`timedOutAtEnd`) and the responses that took longer than 5 s (`lateResponses`). It does this for the whole phase and for requests sent in the measured window. The RTT distributions leave out unanswered requests, so this is their missing count. Requests sent just before the phase end are normally still pending. An unanswered request is forgotten at the phase end, so a late response never lands in the next phase.
- **Windows**: `measurement.windows` has per-window (`--window-ms`, default 1000) RTT and update distributions and sends. Windows are split at the warm-up boundary rather than flagged when they straddle it. They run from the origin to the end of the warm-up and from there to the phase end, so the last warm-up window and the last window can be shorter (`startMs`/`endMs`). A window is flagged `warmup` only when it lies entirely inside the warm-up.
- **Listen queue** (Linux): each phase's `listenQueue` gives two `ListenOverflows`/`ListenDrops` increases from `/proc/net/netstat`: `phase` (from the transition start to the phase end) and `measured` (from origin + warm-up to the phase end). `listenQueue.readAt` records when each read actually happened. `meta.listenQueue.run` covers the whole run. The counters are host-wide (network-namespace-wide in a container), which the fields record as `scope: "host-or-netns"`. They describe the server's listen queue only when nothing else on that host or namespace accepts connections. They are absent on macOS.
- **Client events** (`events` in the scenario, or `--move-to-rate`): each player also sends client events, each on its own spread schedule (`period = 1000 / ratePerSecond`, a per-connection offset keyed by event name). Events get no response, so they never enter RTT; RTT stays on the actions. `measurement.events` gives, per event, the sends in the measured window, the achieved rate overall and per player, and the target (rate × average joined connections).
- **State-update payload bytes**: the payload size of every state update is recorded: the message as `ws` hands it over, not the TCP bytes. When permessage-deflate is negotiated (the `ws` client offers it), that is the size after inflation, so `connectionLifecycle.permessageDeflate` (per phase) and `meta.permessageDeflate` (over the run) count the connections opened with and without it. `measurement.stateUpdates` gives the updates in the measured window, updates per second (overall and per player), and the payload size in bytes (`bytesMean` and the `bytes` distribution, p99 included). Like the update intervals, a connection's first update (its join snapshot) is left out. The HTML report shows updates per player per second, payload bytes mean / p99 and events per player per second next to RTT.
- **Load client CPU**: every worker samples its own process CPU time (`process.cpuUsage()`, user + system) every 500 ms through the phase. `measurement.clientCpu` gives each worker's share of one core over the measured window (`perWorkerPct` min / mean / max), the orchestrator process sampled the same way (`orchestratorPct`, null if its samples miss the window), workers and orchestrator together (`totalPct`, % of one core) and the cores the client sees. A worker near 100% means its event loop, not the server, may be adding to RTT; the HTML report shows it next to the other phase columns. Server CPU comes from the system metrics (below).
- **Server CPU**: `monitoring/collect-system-metrics.sh` (a wrapper around `collect-system-metrics.mjs`) samples the server process every second: its cumulative CPU time (`cpuSec`, user + system; `/proc/<pid>/stat` on Linux, `ps -o time=` elsewhere) with a monotonic clock (`monoMs`) and the wall clock (`tsMs`), plus RSS and load. Each sample's `cpuPct` in the report is the rate over the interval since the previous sample (100 = one core; null for the first). The report's `serverCpu` block gives, per phase over its measured window, the time-weighted mean, p95 and max of those rates, from the intervals wholly inside the window. The sampler used `ps -o %cpu` before 2026-11-05: on Linux that is CPU time over the process's whole lifetime, so `cpuPct` in older reports lags the load and includes start-up and the join ramp; those files have no `cpuSec` and give `serverCpu: null`. Re-derive or re-measure before citing their server CPU.
- **Load client event-loop delay**: every worker monitors its own event loop (`perf_hooks.monitorEventLoopDelay`, 1 ms resolution) from the measured window's start to the phase end. `measurement.clientLoopDelay` gives the delay beyond the 1 ms sampling interval: p50 and p99 across workers (`mean`, and `max` for the worst worker) and the longest single delay (`maxMs`), in ms. The HTML column shows the worst worker's p50 / p99 and the longest delay. A high p99 there means late frame reads and send timers on the client, which inflate RTT and send lag.
- **Closest to the old tool**: `--layout per-connection --connect burst --boundary abrupt --send lockstep --warmup-seconds 0`.

## Scenario Format

Scenarios are JSON files under `scenarios/<landType>/` (`hero-defense/`, `visibility-test/`). Each contains:
- `serverUrl` and `landType` (optional): the land type sent in every join. Without `landType` it is the last segment of a `/game/<landType>` server path, else `hero-defense`.
- `actions` with weights + payload templates
- `phases` (`preflight`, `steady`, `postflight`) with durations, rooms, players, rates, and thresholds

- `events` (optional): client events every player sends, e.g. `[{ "name": "MoveTo", "ratePerSecond": 2, "payloadGenerator": "moveTo" }]`, and `eventSeed` (optional integer, default 1) for the payload generators.

**Moving players** (`--move-to-rate <n>`, `--event-seed <n>`): players send `MoveTo` client events at `n` per second each, overlaid on any scenario and any CLI overrides. A positive rate sets (or replaces) the scenario's `MoveTo` event; `0` removes it; without the flag the scenario's `events` stand. The `moveTo` generator draws each target uniformly inside the hero-defense world (128 × 72) from a PRNG seeded per connection by the event seed, the event name and the connection, so with the same seed every connection draws the same target sequence: its n-th target is the same in every run. How many targets a connection sends depends on when it joined, so two runs share the same prefix of each sequence, not necessarily the same count. Targets are encoded with the SDK's `Position2`/`IVec2` (fixed point), loaded from `@swiftstatetree/sdk` (a `file:` dependency on `sdk/ts`; `npm install` builds it). `meta.runConfig` records the effective `events`, the `eventSeed` and the client's `nodeVersion`. `scenarios/hero-defense/moving-players.json` is `default.json` with `MoveTo` at 2/s as an example; for capacity runs, add `--move-to-rate 2` to the usual scenario and overrides instead.

**Visibility test land** (`scenarios/visibility-test/`, #65): the land on `/game/visibility-test` moves 40 entities and syncs them through a per-player filter, so it exercises per-player projection at load. Its scenarios use 4 players per room (one per viewer slot), `SetMotionAction { enabled: true }` as the RTT action (it keeps the entities moving), and `MoveViewer` client events at 2/s from the `moveViewer` generator, which draws each viewer position uniformly inside the 100 × 100 arena the same way `moveTo` does. The land has no `StateSync`: it syncs in each 50 ms tick, so the scenarios set `syncIntervalMs: 50` and `updateP95: 70`. In a 1-room smoke run on a Mac, clients saw 20 updates per player per second, with intervals of p50 50 ms and p95 53 ms, and update sizes of p50 99 B and p95 197 B (broadcast and per-player frames together).

**Thresholds and sync interval**: For lands that use `StateSync(every: N ms)`, set update thresholds to **N + margin** (e.g. Hero Defense: StateSync 100ms → `updateP95: 120`, `updateP99: 250`). This accounts for client-observed interval including event-loop jitter; do not set `updateP95` to exactly N or healthy runs may fail. You can set **`syncIntervalMs`** in the scenario root (e.g. `100`); if a phase’s `thresholds` omits `updateP95`/`updateP99`, they are derived as `syncIntervalMs + 20` and `250`.

## Metrics

- **rtt**: Round-trip time from the action's intended send time (`spread`) or actual send (`lockstep`) to receiving its actionResponse. Measures server + network + client-side queueing.
- **update**: **Client-observed** interval between consecutive state updates (time between handling one sync's state and the next in the same connection). One sync is one update, even when it arrives as two frames: in the opcode encodings (messagepack, opcodeJsonArray) a land with per-player fields sends each session the merged broadcast frame (opcode 107) and then its per-player state frame. A plain state frame within `SYNC_FRAME_GROUP_MS` (10 ms) after a 107 frame, with no state frame between them, is counted as part of that sync, and its bytes are added to the sync's size. Hero Defense has only broadcast fields and sends one 107 frame per sync, so its counts are the same with or without the grouping. The window is a timing heuristic: the frames carry no tick marker, and the server sends a per-player frame without a 107 frame when a sync changes only per-player state, so a plain frame after a 107 frame cannot be assigned structurally. Under heavy client load the two halves of one sync can arrive more than 10 ms apart; they then count as two updates again. `measurement.stateUpdates.syncFrameGrouping` reports, per phase, how many plain frames after a 107 frame were `grouped` and how many were `ungroupedAfterBroadcast`. For visibility-test, whose broadcast `tickCount` changes every tick, the second should stay near 0; if it grows with load, that run's update rate and sizes are distorted. Before 2026-11-06 each frame counted as an update, so visibility-test runs from before then show about twice the update rate and half-size updates. Uses `Date.now()` when the `message` callback runs. Hero Defense uses **StateSync(every: 100ms)** = 10 broadcasts/s.
  - **Worst case**: The server sends on time (e.g. at t=0 and t=100ms). The client receives both packets on time, but the *callback* for the second packet runs a few ms late (event loop busy with other connections). So we record "last update" at t=104 instead of t=100 — i.e. we observe 104ms between updates even though the packet arrived in time. So the measured interval = server interval + client processing delay.
  - **Thresholds**: When setting `updateP95` / `updateP99`, use **server sync interval + margin for client jitter** (e.g. 100ms + 20ms = 120ms for Hero Defense). Do not set the threshold to exactly the server interval (100ms), or healthy runs will fail due to client-side jitter.

- **Can we prove the client has no delay?** There is **no direct metric** for client processing delay: Node.js `ws` does not expose packet arrival time, so we only record `Date.now()` when the `message` callback runs. You can use **indirect evidence**:
  - **RTT p95 low** (e.g. &lt; 10ms): action requests and responses are handled quickly → the client event loop is not globally backlogged.
  - **update p50 ≈ server sync interval** (e.g. ~100ms): the median interval between state updates matches the server’s StateSync interval → the server is sending on time.
  - When both hold, **update p95 above the sync interval** (e.g. 104ms vs 100ms) is consistent with occasional client-side jitter, not systematic client delay (which would also raise RTT). The HTML report can show a short note when these conditions are met.

## Log level during load test

**When using the script** (`run-ws-loadtest.sh` or `run-scalability-test.sh`): the script starts GameServer with **`LOG_LEVEL=error`** and redirects all server output to `/tmp/ws-loadtest-gameserver.log`. Only script messages and the final "Report written to ..." appear in the terminal; server logs are not printed. If a run fails or the server crashes, the script prints the tail of that log.

**When you start GameServer manually** (e.g. in another terminal for debugging): set **`LOG_LEVEL=error`** so only errors are shown during the load test. Otherwise the default `info` level will print many lines per connection (e.g. "Client connected", "Client joined", "Received action", "Sending state update"):

```bash
# In the terminal where you run GameServer (performance test: only errors)
LOG_LEVEL=error swift run GameServer
```

Optional: `NO_COLOR=1` for plain text logs (e.g. when redirecting to a file).

## Transport profiling (server-side)

When `--profile` is used with `run-ws-loadtest.sh` or `run-scalability-test.sh`, the GameServer writes **JSONL** to `<output-dir>/transport-profile.jsonl` every second. Each line contains:

- **counters**: actions, stateUpdates, messagesReceived, bytesReceived, disconnects, errors, connectedSessions, joinedSessions
- **lag_ms**: actor ticker drift (expected 1000ms interval vs actual)
- **decode_ms**, **handle_ms**, **encode_ms**, **send_ms**: latency percentiles (p50/p95/p99/max) when samples exist (1% sampling to minimize overhead)

Environment variables (optional): `TRANSPORT_PROFILE_JSONL_PATH`, `TRANSPORT_PROFILE_INTERVAL_MS` (default 1000), `TRANSPORT_PROFILE_SAMPLE_RATE` (default 0.01), `TRANSPORT_PROFILE_MAX_SAMPLES_PER_INTERVAL` (default 500).

## Notes

- Join messages always use JSON.
- Actions use MessagePack opcode arrays after `joinResponse` advertises `messagepack`.
- If the load test times out, the script will terminate `GameServer` and exit.

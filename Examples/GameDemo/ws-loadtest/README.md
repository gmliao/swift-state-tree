# WS Load Test (Hero Defense)

This tool runs a **real WebSocket client** load test for the `hero-defense` land using Node.js `ws` clients.
It supports multi-process workers, phased scenarios, and generates **JSON + HTML** reports.

## Quick Start

```bash
cd Examples/GameDemo/ws-loadtest
npm install
npm run build
bash scripts/run-ws-loadtest.sh --scenario scenarios/hero-defense/default.json
```

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
  --system-metrics monitoring/system-metrics.json
```

## Room layout and connections

- **Layout** (`--layout`, default `rooms`): a phase's `rooms × playersPerRoom` connections join `rooms` lands of `playersPerRoom` players (`<runId>-room-p<playersPerRoom>-<room>`). Whole rooms go to one worker. `--layout per-connection` is the earlier behaviour: one land per connection (`<runId>-<phase>-<worker>-<i>`).
- **Run id**: every land id starts with a new short id per run (`--run-id` to set it), so back-to-back runs on one server never join each other's live or draining lands. `run-scalability-test.sh` restarts the server for every run anyway; the id matters when the CLI runs against a long-lived server.
- **Connect** (`--connect`, default `ramp`): new connections open at about `--connect-rate` per second over all workers (default 1000/s), each jittered inside its slot. `--connect burst` opens them all at once (join-storm tests). A phase whose ramp needs longer than the phase fails the run before it starts. `--allow-partial-ramp` runs it anyway with a warning, and the phase's `connectionLifecycle` then shows `started` and `joinedAtEnd` below `target`.
- **Across phases** (`--boundary`, default `clean`): workers live for the whole run. A connection whose room is also in the next phase stays open; the others are closed with a close frame (code 1000) before the next phase opens new ones. At the end every connection is closed the same way. With the `rooms` layout, phases with the same `playersPerRoom` share lands and connections. `--boundary abrupt` drops those sockets without a close frame instead (the server sees FIN or RST, depending on unread data).
- **Legacy topology**: `--layout per-connection --connect burst` gives the same topology and connect burst as the old tool. Phase boundaries still close cleanly, unlike the old tool's resets, so the boundary load and the first seconds of each phase differ. Add `--boundary abrupt` to drop the sockets at boundaries as the old tool did. The sockets are then dropped when the next phase starts rather than as each worker exits.
- **Report**: `meta.runConfig` records the run id, layout, connect mode and rate, boundary mode, workers, and every phase's rooms, players, connections, lands and ramp time. Each phase has `layout` (lands, players per land) and `connectionLifecycle`: target, started, joined at the end, opened, reused, closed at start, ramp duration, and close counts split by initiator and code, plus the first 200 close records. `disconnectRate` counts only closes the client didn't ask for, including server closes on connections between phases. `meta.shutdownCloses` covers the end of the run.

## Sending and measurement

- **Send schedule** (`--send`, default `spread`): each client sends at `origin + offset + n · period` (`period = 1000 / actionsPerSecond` ms). The per-client offset in `[0, period)` comes from a stable hash of the connection, so a land's actions are spread over the tick and sync phase and runs are reproducible. A timer that fires late sends every slot it missed. `--send lockstep` is the earlier behaviour: one timer per worker sends for all of its joined clients at once.
- **RTT origin**: in `spread` mode RTT is measured from the intended send time, so client-side queueing and stalls show up as larger RTT, not as missing samples (no coordinated omission). The report also gives the send lag (actual minus intended), the late sends (more than one period late) and the achieved send rate against the target (joined clients × rate). In `lockstep` mode RTT is measured from the actual send, as before.
- **Warm-up**: RTT and update samples in the first `warmupSeconds` of each phase are excluded from the phase's metrics and thresholds. Set it per phase in the scenario or for all phases with `--warmup-seconds`. The default is the phase's connect ramp + 2 s, at most half the phase. Each phase's `measurement` block gives the resolved warm-up and the excluded sample counts.
- **Windows**: `measurement.windows` has per-window (`--window-ms`, default 1000) RTT and update distributions and sends, with the warm-up windows flagged.
- **Listen queue** (Linux): each phase's `listenQueue` and `meta.listenQueue` give the `ListenOverflows`/`ListenDrops` increase from `/proc/net/netstat`. The counters are host-wide (namespace-wide in a container), so they describe the server's listen queue when the server runs on the same host. They are absent on macOS.
- **Closest to the old tool**: `--layout per-connection --connect burst --boundary abrupt --send lockstep --warmup-seconds 0`.

## Scenario Format

Scenarios are JSON files under `scenarios/hero-defense/`. Each contains:
- `actions` with weights + payload templates
- `phases` (`preflight`, `steady`, `postflight`) with durations, rooms, players, rates, and thresholds

**Thresholds and sync interval**: For lands that use `StateSync(every: N ms)`, set update thresholds to **N + margin** (e.g. Hero Defense: StateSync 100ms → `updateP95: 120`, `updateP99: 250`). This accounts for client-observed interval including event-loop jitter; do not set `updateP95` to exactly N or healthy runs may fail. You can set **`syncIntervalMs`** in the scenario root (e.g. `100`); if a phase’s `thresholds` omits `updateP95`/`updateP99`, they are derived as `syncIntervalMs + 20` and `250`.

## Metrics

- **rtt**: Round-trip time from the action's intended send time (`spread`) or actual send (`lockstep`) to receiving its actionResponse. Measures server + network + client-side queueing.
- **update**: **Client-observed** interval between consecutive state-update messages (time between handling one `stateUpdate` and the next in the same connection). Uses `Date.now()` when the `message` callback runs. Hero Defense uses **StateSync(every: 100ms)** = 10 broadcasts/s.
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

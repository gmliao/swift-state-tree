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

Options: `--runs <N>`, `--no-scale-by-rooms`, `--room-counts "N1 N2 N3"` (scale by room count), `--workers <N>`, `--scenario <path>`, `--output-dir <dir>`, `--startup-timeout <s>`, `--delay <s>` (seconds between runs). Output is written to `results/scalability-<timestamp>/` with a `summary.json`, per-run logs/reports, and a **summary.html**. The summary report is generated as a **static HTML** (no runtime Vue/JS required): the template is `scripts/scalability_summary_template.html` and `scripts/render-summary-html.js` renders `summary.json` into the final HTML, so you can edit the template and re-run the script to change the report layout.

## CLI

```bash
node dist/cli.js \
  --scenario scenarios/hero-defense/default.json \
  --workers 4 \
  --output-dir results \
  --system-metrics monitoring/system-metrics.json
```

## Scenario Format

Scenarios are JSON files under `scenarios/hero-defense/`. Each contains:
- `actions` with weights + payload templates
- `phases` (`preflight`, `steady`, `postflight`) with durations, rooms, players, rates, and thresholds

**Thresholds and sync interval**: For lands that use `StateSync(every: N ms)`, set update thresholds to **N + margin** (e.g. Hero Defense: StateSync 100ms → `updateP95: 120`, `updateP99: 250`). This accounts for client-observed interval including event-loop jitter; do not set `updateP95` to exactly N or healthy runs may fail. You can set **`syncIntervalMs`** in the scenario root (e.g. `100`); if a phase’s `thresholds` omits `updateP95`/`updateP99`, they are derived as `syncIntervalMs + 20` and `250`.

## Metrics

- **rtt**: Round-trip time (client sends action → client receives actionResponse). Measures server + network.
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

## Notes

- Join messages always use JSON.
- Actions use MessagePack opcode arrays after `joinResponse` advertises `messagepack`.
- If the load test times out, the script will terminate `GameServer` and exit.

# Server Metrics File (Shared by ws-loadtest and server-loadtest)

**Goal:** Optional server-side metrics writing to a file, configured via environment variables at startup. Both **GameServer** (used by ws-loadtest) and **ServerLoadTest** (in-process load test) can enable it with the same env contract and file format.

## Why

- ws-loadtest: needs server-side state (totalLands, totalPlayers) during/after test without polling HTTP.
- server-loadtest: same need; today it only has client-side traffic and system monitoring (pidstat/vmstat). Adding server metrics (lands, players) to the same run would make reports comparable and help find bottlenecks.

## Env contract (shared)

| Variable | Meaning | Default |
|----------|---------|---------|
| `METRICS_OUTPUT_PATH` | Absolute or relative path to write metrics. When set (non-empty), enable writing. | (disabled) |
| `METRICS_INTERVAL_SECONDS` | Seconds between samples. | `1` |

When `METRICS_OUTPUT_PATH` is unset or empty, no file is written and no background task is started.

## File format

- **Format:** One JSON object per line (NDJSON), append-only.
- **Fields per line:** `ts` (Unix seconds), `totalLands` (Int), `totalPlayers` (Int).
- **Example:**
  ```json
  {"ts":1706789120,"totalLands":500,"totalPlayers":2500}
  {"ts":1706789121,"totalLands":500,"totalPlayers":2500}
  ```
- **Parsing:** Scripts (ws-loadtest Node, server-loadtest Python) can read line-by-line; no need to hold full file in memory.

## Where to implement

1. **Shared writer (GameDemo)**  
   - New small module: e.g. `Sources/GameContent/ServerMetricsWriter.swift` or under a shared `Support/` in GameDemo.  
   - API: start a background task that every `METRICS_INTERVAL_SECONDS` calls an async closure `() async -> (totalLands: Int, totalPlayers: Int)`, then appends one JSON line to the file.  
   - Use `ProcessInfo.processInfo.environment["METRICS_OUTPUT_PATH"]` and `METRICS_INTERVAL_SECONDS`; if path is nil/empty, do nothing.

2. **GameServer**  
   - In `main`, after `landHost` is set up and before `landHost.run()`:  
     - If `METRICS_OUTPUT_PATH` is set, start the writer with a provider closure that:  
       - `let lands = await landHost.realm.listAllLands()`  
       - For each `landID` in lands: `if let s = await landHost.realm.getLandStats(landID: landID) { totalPlayers += s.playerCount }`  
       - Return `(lands.count, totalPlayers)`  
   - LandHost already exposes `realm: LandRealm`, so no Hummingbird changes required.

3. **ServerLoadTest**  
   - In `main`, after `server` (LandServer) is created and before the main test loop:  
     - If `METRICS_OUTPUT_PATH` is set, start the same writer with a provider closure that:  
       - `let lands = await server.listLands()`  
       - For each `landID`: `if let s = await server.getLandStats(landID: landID) { totalPlayers += s.playerCount }`  
       - Return `(lands.count, totalPlayers)`  
   - LandServer already conforms to LandServerProtocol (listLands, getLandStats), so no new API.

## Script usage

- **ws-loadtest**  
  - In `run-ws-loadtest.sh`, when starting GameServer:  
    - e.g. `METRICS_OUTPUT_PATH="$ROOT_DIR/monitoring/server-metrics.json" ENABLE_REEVALUATION=false swift run -c release GameServer ...`  
  - After the test, read `monitoring/server-metrics.json` (NDJSON), merge into the report (e.g. `serverSamples` array in JSON/HTML).

- **server-loadtest**  
  - In `run-server-loadtest.sh`, when invoking ServerLoadTest:  
    - e.g. `METRICS_OUTPUT_PATH="$SCRIPT_DIR/results/server-metrics-$$.json" swift run -c release ServerLoadTest ...`  
  - After the run, parse the same NDJSON and merge into the existing monitoring report (e.g. alongside vmstat/pidstat in the HTML or a separate section).

## Optional: connection count

- Today admin API and LandRealm do not expose WebSocket connection (session) count.  
- If needed later, Transport could expose a `sessionCount` (or LandHost could ask the transport) and the writer could add `"connectionCount": N` to each line.  
- For the first version, totalLands + totalPlayers is enough for both load tests.

## Summary

- **One env contract** (`METRICS_OUTPUT_PATH` + optional `METRICS_INTERVAL_SECONDS`).  
- **One file format** (NDJSON: ts, totalLands, totalPlayers).  
- **One shared writer** in GameDemo, used by both GameServer and ServerLoadTest with different provider closures.  
- **Both ws-loadtest and server-loadtest** can enable it at startup and consume the same file in their reporting.

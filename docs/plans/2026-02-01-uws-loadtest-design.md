[English](2026-02-01-uws-loadtest-design.md) | [中文版](2026-02-01-uws-loadtest-design.zh-TW.md)

# UWS Load Test for Hero Defense (Design)

## Goals
- Build a new `ws`-based load tool to validate **stability** and **performance** of `hero-defense`.
- Run real client connections (connect + join + continuous actions).
- Produce a **new JSON + HTML report** format (separate from existing server-loadtest).
- Capture both **client metrics** (RTT, state update cadence, throughput, error/disconnect rate) and **server metrics** (CPU/mem/load).

## Non-Goals
- Reuse `Tools/CLI` scenario format or validation pipeline.
- Support churn (disconnect/reconnect) in the first iteration.
- Support non-`messagepack` encodings in the first iteration.

## Location & Structure
Root: `Examples/GameDemo/uws-loadtest/`
Suggested layout:
```
uws-loadtest/
  package.json
  src/
    cli.ts
    orchestrator.ts
    worker.ts
    scenario.ts
    metrics.ts
    report/
      render-html.ts
  scripts/
    run-uws-loadtest.sh
  scenarios/
    hero-defense/
      default.json
  results/
    uws-loadtest-<timestamp>.json
    uws-loadtest-<timestamp>.html
  monitoring/
    collect-system-metrics.sh
```

## Scenario Format
- Scenario is JSON (versioned), stored under `scenarios/hero-defense/`.
- `phases`: `preflight`, `steady`, `postflight`.
- Each phase can define: `durationSeconds`, `rooms`, `playersPerRoom`, `actionsPerSecond`,
  `verify` (boolean), `joinPayloadTemplate`, `thresholds`.
- Defaults: if `rooms` not specified → `500`. Other defaults are set in code for missing fields.
- Actions/events are defined by name and payload template (with placeholders like `{playerId}`, `{randInt:1:9999}`).
- Thresholds are part of the scenario (error rate, disconnect rate, P95/P99 for RTT and state update cadence).

## Execution Model
- Orchestrator reads scenario and computes total connections (`rooms * playersPerRoom`).
- Multi-process workers are launched, **distributed by connection count**.
- Each worker:
  - Opens `ws` sockets, performs join with templated payload.
  - Sends actions/events at `actionsPerSecond` per player.
  - In `steady` phase, **no per-message assertions**; only counters and minimal health checks.
  - In `preflight`/`postflight`, optional verification to ensure correctness.

## Metrics & Thresholds
Client metrics:
- **RTT**: request → response timing (P50/P95/P99).
- **State update cadence**: time between updates (P50/P95/P99).
- Throughput, error rate, disconnect rate.

Server metrics:
- CPU, memory, load/IO via system sampling (macOS/Linux).
- Monitoring is executed by script and merged into the report.

Threshold behavior:
- If thresholds fail, mark report as failed but **do not** change exit code.

## Reporting
- New JSON schema tailored to uws load test.
- HTML renderer that visualizes:
  - RTT percentiles over time
  - State update cadence
  - Error/disconnect rates
  - Server CPU/memory charts
- Output to `results/uws-loadtest-<timestamp>.{json,html}`.

## Runtime Defaults
- Encoding: `messagepack` only.
- Server: auto-start `GameServer`, wait for readiness, terminate on timeout.
- URL is configurable via CLI flags; default `ws://localhost:8080/game/hero-defense`.

## Risks & Mitigations
- **Validation overhead**: keep full verification only in `preflight`/`postflight`.
- **No churn coverage**: document as future work.
- **Server readiness**: script waits and hard-kills on timeout to prevent stuck runs.

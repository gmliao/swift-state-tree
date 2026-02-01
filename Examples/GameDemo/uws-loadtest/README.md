# UWS Load Test (Hero Defense)

This tool runs a **real WebSocket client** load test for the `hero-defense` land using Node.js `ws` clients.
It supports multi-process workers, phased scenarios, and generates **JSON + HTML** reports.

## Quick Start

```bash
cd Examples/GameDemo/uws-loadtest
npm install
npm run build
bash scripts/run-uws-loadtest.sh --scenario scenarios/hero-defense/default.json
```

Reports are written to:
```
Examples/GameDemo/uws-loadtest/results/
```

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

## Notes

- Join messages always use JSON.
- Actions use MessagePack opcode arrays after `joinResponse` advertises `messagepack`.
- If the load test times out, the script will terminate `GameServer` and exit.

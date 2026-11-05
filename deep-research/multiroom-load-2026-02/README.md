# multiroom-load-2026-02: multi-room load test and payload size, February 2026

Raw evidence from 2026-02-06 for two questions, measured on the NIO transport with hero-defense (5 players per room):

1. Does the server hold 100, 300 and 500 rooms within the sync budget? ws-loadtest, 3 runs.
2. What does one sync cost in bytes per room, by encoding? EncodingBenchmark scalability matrix, JSON object against opcode MessagePack with PathHash.

This folder was called `emse-artifacts/` until 2026-11-05. Links pinned to older commits still use that name.

## Contents

| Path | What it is |
|---|---|
| `evidence-2026-02-06-nio-stage3-100-300-500/scalability-2026-02-06T14-24-28/` | ws-loadtest suite: `run-1..3` (+ logs), `summary.json`, `summary.html` |
| `evidence-2026-02-06-nio-stage3-100-300-500/encoding-benchmark/` | EncodingBenchmark envelopes (metadata + results) for `json-object` and `messagepack-pathhash`, 5 players per room, 200 iterations, 2 ticks per sync |
| `artifacts/` | Tables (`*.md`, `*.csv`) and an SVG figure generated from the envelopes |
| `generate_tables.py` | Rebuilds `artifacts/` (stdlib only) |

## Commands

```bash
# Load test (as recorded in evidence-*/README.txt)
cd Examples/GameDemo/ws-loadtest && bash scripts/run-scalability-test.sh --room-counts "100 300 500" --runs 3 --output-dir results

# Rebuild the tables and figure
cd deep-research/multiroom-load-2026-02
E=evidence-2026-02-06-nio-stage3-100-300-500/encoding-benchmark
python3 generate_tables.py --out-dir artifacts \
  --json-object $E/scalability-matrix-json-object-ppr5-200iterations-tick2-2026-02-06T14-11-36Z.json \
  --messagepack $E/scalability-matrix-messagepack-pathhash-ppr5-200iterations-tick2-2026-02-06T14-13-32Z.json
```

## Caveats

- The load client was the February 2026 version. Its methodology was revised in November 2026: paced joins, a warm-up, per-message RTT, and 5-player rooms instead of one room per connection. See #106 for the attribution runs. Its latency and CPU figures aren't comparable with runs from the revised client.
- The MessagePack wire format changed on 2026-01-30 (opcode 107, `4423693`), so MessagePack bytes here differ from January 2026 runs. `../snapshot-baseline/` re-measures both room ranges at one commit.
- Payload bytes include fields that should not have been sent: `.serverOnly` fields of state nodes inside `[String: X]` / `[PlayerID: X]` maps (#175). They will be re-measured after the fix.

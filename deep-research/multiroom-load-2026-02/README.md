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
| `artifacts/` | Tables (`*.md`, `*.csv`) and an SVG figure for **10/30/50 rooms**, from the 2026-01-25 EncodingBenchmark run (MessagePack 4,572 / 13,612 / 22,713 B per sync). Those input envelopes are not in this folder. |
| `generate_tables.py` | Builds those tables from two EncodingBenchmark envelopes (stdlib only). It keeps only 5 players per room at 10, 30 and 50 rooms. |

## Commands

```bash
# Load test: one run per room count (see Caveats on the recorded --runs 3)
cd Examples/GameDemo/ws-loadtest && bash scripts/run-scalability-test.sh --room-counts "100 300 500" --output-dir results

# Tables from an EncodingBenchmark scalability run that includes 10/30/50 rooms
cd deep-research/multiroom-load-2026-02
python3 generate_tables.py --out-dir <dir> --json-object <json-object envelope> --messagepack <messagepack-pathhash envelope>
```

The 2026-02-06 envelopes in `evidence-*/encoding-benchmark/` cover 100/300/500 rooms, so `generate_tables.py` produces empty tables from them (checked 2026-11-05). Read those envelopes directly. `../snapshot-baseline/` re-measures both room ranges at one commit with its own `regenerate.py --check`.

## Caveats

- **One run per room count.** The command recorded in `evidence-*/README.txt` passes `--runs 3`, but with `--room-counts` the script ignored `--runs`. Its `run-1..3` are one run each at 100, 300 and 500 rooms, not three runs per room count. The script now refuses `--runs` with a room list.
- **This run is verified intact.** When it ran, the script had a bug, fixed on 2026-11-06 (`e6f30a74`, since 2026-02-02): its TIME_WAIT wait reused the run loop's index, so after a long enough wait it could skip the remaining room counts while the summary still read as clean. This suite wasn't hit. `summary.json` lists 3/3 runs at 100, 300 and 500 rooms, and run-3's report has 2500 connections in steady state (500 rooms × 5 players).
- The load client was the February 2026 version. Its methodology was revised in November 2026: paced joins, a warm-up, per-message RTT, and 5-player rooms instead of one room per connection. See #106 for the attribution runs. Its latency and CPU figures aren't comparable with runs from the revised client.
- The MessagePack wire format changed on 2026-01-30 (opcode 107, `4423693`), so MessagePack bytes here differ from January 2026 runs. `../snapshot-baseline/` re-measures both room ranges at one commit.
- Payload bytes include fields that should not have been sent: `.serverOnly` fields of state nodes inside `[String: X]` / `[PlayerID: X]` maps (#175). They will be re-measured after the fix.

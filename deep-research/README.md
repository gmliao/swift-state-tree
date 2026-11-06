[English](README.md) | [中文版](README.zh-TW.md)

# Experiments

Experiment data for SwiftStateTree.

Each folder answers one question and has its own README (question, environment, commands, results, caveats). Where there's a `regenerate.py`, `python3 regenerate.py --check` confirms that the README's tables match the raw results.

| Folder | Question | Last updated | Regenerate |
|---|---|---|---|
| [recomputation-cost/](recomputation-cost/README.md) | How large is the re-evaluation record that reproduces a land's sync stream, compared with the stream itself, per input cadence and player count? | not run yet | `regenerate.py` |
| [replay-scale-fp-perturbation/](replay-scale-fp-perturbation/README.md) | Does per-tick state-hash replay stay at 0 mismatches over tens of recordings and thousands of ticks, and how fast does it detect injected floating/fixed-point perturbations? | 2026-11-04 | `regenerate.py`, `crossarch-verify.sh` |
| [snapshot-baseline/](snapshot-baseline/README.md) | At equal encoding, how much does delta sync save over a per-sync full snapshot, and does the saving track the changed fraction? | 2026-09-15 (wording 2026-11-05) | `run.sh`, `collect.py`, `regenerate.py` |
| [single-room-entity-scaling/](single-room-entity-scaling/README.md) | In one hero-defense room, does `bytesPerSync` grow linearly with players and monsters? | 2026-08-31 | `regenerate.py` |
| [multiroom-load-2026-11-server-ab/](multiroom-load-2026-11-server-ab/README.md) | Under the same load client, how do the `b629861` and `ee8a407a` servers compare in CPU, RTT and input-to-visible latency at 100–1000 rooms of 5 players? | 2026-11-06 | `regenerate.py`, `summarize_host.py` |
| [multiroom-load-2026-11/](multiroom-load-2026-11/README.md) | With the send backlog bound at its defaults, does the server hold 100, 300 and 500 rooms of 5 players with zero disconnects, and how do RTT, update interval and CPU compare across three suites and with earlier runs? | 2026-11-06 | `regenerate.py`, `summarize_host.py` |
| [multiroom-load-2026-02/](multiroom-load-2026-02/README.md) | Raw multi-room load-test and EncodingBenchmark evidence from February 2026 (NIO transport, 100/300/500 rooms), with the generator for its tables and figure | 2026-02-07 | `generate_tables.py` |

The machine, toolchain and commit for each result are in that folder's README; results from different machines are compared only as trends.

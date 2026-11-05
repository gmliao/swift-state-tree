[English](README.md) | [中文版](README.zh-TW.md)

## Experiments

Each folder answers one question and has its own README (question, environment, commands, results, caveats). Where there's a `regenerate.py`, `python3 regenerate.py --check` confirms that the README's tables match the raw results.

| Folder | Question | Last updated | Regenerate |
|---|---|---|---|
| [replay-scale-fp-perturbation/](replay-scale-fp-perturbation/README.md) | Does per-tick state-hash replay stay at 0 mismatches over tens of recordings and thousands of ticks, and how fast does it detect injected floating/fixed-point perturbations? | 2026-11-04 | `regenerate.py`, `crossarch-verify.sh` |
| [snapshot-baseline/](snapshot-baseline/README.md) | At equal encoding, how much does delta sync save over a per-sync full snapshot, and does the saving track the changed fraction? | 2026-09-15 (wording 2026-11-05) | `run.sh`, `collect.py`, `regenerate.py` |
| [single-room-entity-scaling/](single-room-entity-scaling/README.md) | In one hero-defense room, does `bytesPerSync` grow linearly with players and monsters? | 2026-08-31 | `regenerate.py` |
| [emse-artifacts/](emse-artifacts/) | Raw multi-room load-test evidence from February 2026 (NIO stage 3, 100/300/500 rooms), with the generator for its tables and figures | 2026-02-07 | `generate_emse_artifacts.py` |

The machine, toolchain and commit for each result are in that folder's README; results from different machines are compared only as trends.

## About This Document

This document is the result of a deep research and analysis process conducted with the assistance of AI tools.

AI was used as a research accelerator for:
- literature exploration and cross-referencing
- hypothesis expansion and counter-argument generation
- structural organization of complex architectural concepts

All conclusions, architectural judgments, and trade-off decisions were made by the author based on engineering experience and critical evaluation.
This document should be considered an engineering research note rather than an academic proof.

## Documents

- [LSP-Enhanced AI and ECS Architecture Report (zh-TW)](lsp-ai-ecs-architecture-report.zh-TW.md)

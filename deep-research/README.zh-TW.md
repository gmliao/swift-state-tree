[English](README.md) | [中文版](README.zh-TW.md)

## 實驗

Each folder answers one question and has its own README (question, environment, commands, results, caveats). Where there's a `regenerate.py`, `python3 regenerate.py --check` confirms that the README's tables match the raw results.

| Folder | Question | Last updated | Regenerate |
|---|---|---|---|
| [replay-scale-fp-perturbation/](replay-scale-fp-perturbation/README.md) | Does per-tick state-hash replay stay at 0 mismatches over tens of recordings and thousands of ticks, and how fast does it detect injected floating/fixed-point perturbations? | 2026-11-04 | `regenerate.py`, `crossarch-verify.sh` |
| [snapshot-baseline/](snapshot-baseline/README.md) | At equal encoding, how much does delta sync save over a per-sync full snapshot, and does the saving track the changed fraction? | 2026-09-15 (wording 2026-11-05) | `run.sh`, `collect.py`, `regenerate.py` |
| [single-room-entity-scaling/](single-room-entity-scaling/README.md) | In one hero-defense room, does `bytesPerSync` grow linearly with players and monsters? | 2026-08-31 | `regenerate.py` |
| [emse-artifacts/](emse-artifacts/) | Raw multi-room load-test evidence from February 2026 (NIO stage 3, 100/300/500 rooms), with the generator for its tables and figures | 2026-02-07 | `generate_emse_artifacts.py` |

The machine, toolchain and commit for each result are in that folder's README; results from different machines are compared only as trends.

## 關於本文件

本文件為作者主導的深度研究與分析整理，過程中使用 AI 工具協助。

AI 作為研究加速器，用於：
- 文獻探索與交叉參照
- 假設擴展與反例生成
- 複雜架構概念的結構化整理

所有結論、架構判斷與取捨由作者基於工程經驗與批判性評估做出。
本文件應視為工程研究筆記，而非學術證明。

## 文件

- [智能代理時代的架構重構：LSP 增強型 AI 與 ECS 系統化架構的深度評估報告](lsp-ai-ecs-architecture-report.zh-TW.md)

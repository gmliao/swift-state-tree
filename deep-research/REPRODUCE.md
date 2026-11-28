# Reproducing the measurement snapshot

This branch (`artifact/measurements-2026-11`) holds the files of tag `measurements-2026-11.6` (commit `988332383789ee8fb36990c62fb5f287a08929f1`) unchanged. Merge commits that keep the files unchanged add three run commits as ancestors: `dc6f85e7419e270981ea5aeb4b272b1d48f05700` (tag `perturb-serveronly-runner-2026-11`, the runner of `replay-scale-fp-perturbation`'s server-only cell), `b8e798b10679717aa261fb59bb13b2480c229204` (`snapshot-baseline`) and `08863744484c9c71495fe5bd28cac86bdbb1c0f9` (`multiroom-load-2026-02`). Every run commit below can be checked out from this branch's history.

For each topic, the table gives the commits its README names for the published results, and the command that checks the README's tables against the raw results in the folder. Machines, toolchains and run commands are in each topic's README.

## Checking the tables

Run each check from the topic's folder:

```bash
cd deep-research/<topic>
python3 regenerate.py --check
```

The check reads only the files in the folder and needs Python 3 with its standard library: no build, no network. It exits 0 and prints `OK` (or "… are current.") when the README matches the results, and exits non-zero when it doesn't. `bash deep-research/run-tests.sh` runs the scripts' own tests.

## Topics

| Topic | Run commit(s), from the topic's README | Check |
|---|---|---|
| [entity-delta-baseline](entity-delta-baseline/README.md) | `75222b87eb008b1ad94e99d7ae96b83528c9d0a4` | `python3 regenerate.py --check` |
| [external-input-failure](external-input-failure/README.md) | `022d8fdbca966f8df56f1fc86d29421b154ce7a0` | `python3 regenerate.py --check` |
| [multiroom-load-2026-02](multiroom-load-2026-02/README.md) | Not named in the README. The EncodingBenchmark envelopes record `08863744484c9c71495fe5bd28cac86bdbb1c0f9` (branch `feat/nio-websocket-transport`), which is an ancestor of this branch | none: raw February 2026 evidence; `generate_tables.py` has no check mode |
| [multiroom-load-2026-11](multiroom-load-2026-11/README.md) | MoveTo arms: `695fe86cb985752293dc184ff4d650b0689d90c2`; pre-refreeze record: `ee8a407a4c0697afbd401d01f843aa09f4aafb72` | `python3 regenerate.py --check` |
| [multiroom-load-2026-11-server-ab](multiroom-load-2026-11-server-ab/README.md) | server A: `b629861fdf18e1a0621d85cde56e0e9d93ffec57`; server B: `ee8a407a4c0697afbd401d01f843aa09f4aafb72`; load client: `9b41c5a91c98dee213771b3174073beb798e9569` | `python3 regenerate.py --check` |
| [network-impairment-2026-11](network-impairment-2026-11/README.md) | published set: `48962faea5bb47044620a5ee0e41505c6d9e77c1`; #490 re-run (`results/rerun-490/`): `03d6538110cb4ada93d0ccfde9e735d873cdfbeb` | `python3 regenerate.py --check` |
| [recomputation-cost](recomputation-cost/README.md) | `75222b87eb008b1ad94e99d7ae96b83528c9d0a4` | `python3 regenerate.py --check` |
| [replay-scale-fp-perturbation](replay-scale-fp-perturbation/README.md) | record format 3.1 batches and Part B's original cells: `022d8fdbca966f8df56f1fc86d29421b154ce7a0`; Part B's server-only cell: `dc6f85e7419e270981ea5aeb4b272b1d48f05700`; the original Part A/B record: `d23d66d8027036027d1e59218494137c2c6fa2d5`. Earlier re-measurements name their commits in their own tables | `python3 regenerate.py --check` |
| [single-room-entity-scaling](single-room-entity-scaling/README.md) | current record and wire-form ablation: `75222b87eb008b1ad94e99d7ae96b83528c9d0a4`; pre-refreeze record: `648fce5058a239d8ea8147f86297d5e64ef40063`, `9f65c9e071dd98353ccfea873911d3bf331503e0` | `python3 regenerate.py --check` |
| [snapshot-baseline](snapshot-baseline/README.md) | current record: `75222b87eb008b1ad94e99d7ae96b83528c9d0a4`; pre-refreeze record: `b8e798b10679717aa261fb59bb13b2480c229204` (from PR #57; an ancestor of this branch), `c0118d6b8c3b24292f4625cefbf9d86fd025c2ce`, `d2c647b4119e81c843d5c386e4788c24079bad92` | `python3 regenerate.py --check` |
| [visibility](visibility/README.md) | `75222b87eb008b1ad94e99d7ae96b83528c9d0a4` | `python3 regenerate.py --check` |
| [wire-ablation-2026-11](wire-ablation-2026-11/README.md) | `6f3783aadc34ea2390e2fe8575ad9591b756935c`; its `Sources/` and `Package.swift` trees equal those of `75222b87eb008b1ad94e99d7ae96b83528c9d0a4` | `python3 regenerate.py --check` |

All the checks above passed on this branch on 2026-11-28 with Python 3.14.5.

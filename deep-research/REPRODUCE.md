# Reproducing the measurement snapshot

This branch (`artifact/measurements-2026-11`) holds the files of tag `measurements-2026-11.6` (commit `988332383789ee8fb36990c62fb5f287a08929f1`) unchanged. Merge commits that keep the files unchanged add three run commits as ancestors: `dc6f85e7419e270981ea5aeb4b272b1d48f05700` (tag `perturb-serveronly-runner-2026-11`, the runner of `replay-scale-fp-perturbation`'s server-only cell), `b8e798b10679717aa261fb59bb13b2480c229204` (`snapshot-baseline`) and `08863744484c9c71495fe5bd28cac86bdbb1c0f9` (`multiroom-load-2026-02`). Every run commit below can be checked out from this branch's history.

For each topic, the table gives the commits its README names for the published results, and the command that checks the README's tables against the raw results in the folder. Machines and run commands are in each topic's README; the toolchains and a container to rebuild in are under [Environment](#environment).

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
| [multiroom-load-2026-02](multiroom-load-2026-02/README.md) | Not named in the README. The EncodingBenchmark envelopes record `08863744484c9c71495fe5bd28cac86bdbb1c0f9` (the envelopes record branch `feat/nio-websocket-transport`), which is an ancestor of this branch | none: raw February 2026 evidence; `generate_tables.py` has no check mode |
| [multiroom-load-2026-11](multiroom-load-2026-11/README.md) | MoveTo arms: `695fe86cb985752293dc184ff4d650b0689d90c2`; pre-refreeze record: `ee8a407a4c0697afbd401d01f843aa09f4aafb72`; plateau runs (data not in the folder, not covered by `--check`): `f6098c4b8db104184bfba7b7028e84e0267151c9` | `python3 regenerate.py --check` |
| [multiroom-load-2026-11-server-ab](multiroom-load-2026-11-server-ab/README.md) | server A: `b629861fdf18e1a0621d85cde56e0e9d93ffec57`; server B: `ee8a407a4c0697afbd401d01f843aa09f4aafb72`; load client: `9b41c5a91c98dee213771b3174073beb798e9569` | `python3 regenerate.py --check` |
| [network-impairment-2026-11](network-impairment-2026-11/README.md) | published set: `48962faea5bb47044620a5ee0e41505c6d9e77c1`; #490 re-run (`results/rerun-490/`): `03d6538110cb4ada93d0ccfde9e735d873cdfbeb` | `python3 regenerate.py --check` |
| [recomputation-cost](recomputation-cost/README.md) | `75222b87eb008b1ad94e99d7ae96b83528c9d0a4` | `python3 regenerate.py --check` |
| [replay-scale-fp-perturbation](replay-scale-fp-perturbation/README.md) | record format 3.1 batches and Part B's original cells: `022d8fdbca966f8df56f1fc86d29421b154ce7a0`; Part B's server-only cell: `dc6f85e7419e270981ea5aeb4b272b1d48f05700`; the original Part A/B record: `d23d66d8027036027d1e59218494137c2c6fa2d5`. Earlier re-measurements name their commits in their own tables | `python3 regenerate.py --check` |
| [single-room-entity-scaling](single-room-entity-scaling/README.md) | current record and wire-form ablation: `75222b87eb008b1ad94e99d7ae96b83528c9d0a4`; pre-refreeze record: `648fce5058a239d8ea8147f86297d5e64ef40063`, `9f65c9e071dd98353ccfea873911d3bf331503e0` | `python3 regenerate.py --check` |
| [snapshot-baseline](snapshot-baseline/README.md) | current record: `75222b87eb008b1ad94e99d7ae96b83528c9d0a4`; pre-refreeze record: `b8e798b10679717aa261fb59bb13b2480c229204` (from PR #57; an ancestor of this branch), `c0118d6b8c3b24292f4625cefbf9d86fd025c2ce`, `d2c647b4119e81c843d5c386e4788c24079bad92` | `python3 regenerate.py --check` |
| [visibility](visibility/README.md) | `75222b87eb008b1ad94e99d7ae96b83528c9d0a4` | `python3 regenerate.py --check` |
| [wire-ablation-2026-11](wire-ablation-2026-11/README.md) | `6f3783aadc34ea2390e2fe8575ad9591b756935c`; its `Sources/` and `Package.swift` trees equal those of `75222b87eb008b1ad94e99d7ae96b83528c9d0a4` | `python3 regenerate.py --check` |

All the checks above passed on this branch on 2026-11-28 with Python 3.14.5.

## Environment

The checks above need no build. To rebuild a run commit, check out that commit, not this branch, and build it with the toolchain its records name. The table below gives the toolchain each topic's records name, read from the result files (`swiftVersion` in the EncodingBenchmark and ServerLoadTest envelopes, `swift_version` or `swift` in the results' `meta`, `toolchain.txt` beside the ws-loadtest reports) and from the README.

### Container for the Swift 6.2.4 records

Image: `swift@sha256:e508ef1e4be68087f720de622b91cbf1e32799a7aa96134b35e6f1a1d656db7a`. The records name the tag `swift:6.2.4-noble` and no digest. This digest is the `swift:6.2.4-noble` image (created 2026-10-26) that the measurement host's containers were created from. The tag has since moved, so pull the image by digest. The image has Swift 6.2.4 and git. Python and Node are added as below, giving Python 3.12.3 (Ubuntu 24.04) and Node v24.22.2.

```bash
docker volume create sst-repro-624-src
docker run -d --name sst-repro-624 -v sst-repro-624-src:/work -w /work \
  swift@sha256:e508ef1e4be68087f720de622b91cbf1e32799a7aa96134b35e6f1a1d656db7a sleep infinity
docker exec sst-repro-624 sh -c 'apt-get update && apt-get install -y python3 curl xz-utils ca-certificates'
docker exec sst-repro-624 sh -c 'cd /tmp && V=v24.22.2 &&
  curl -fsSLO https://nodejs.org/dist/$V/node-$V-linux-x64.tar.xz &&
  curl -fsSLO https://nodejs.org/dist/$V/SHASUMS256.txt &&
  grep " node-$V-linux-x64.tar.xz\$" SHASUMS256.txt | sha256sum -c - &&
  tar -xJf node-$V-linux-x64.tar.xz -C /usr/local --strip-components=1'
docker exec sst-repro-624 git clone https://github.com/gmliao/swift-state-tree.git /work/swift-state-tree
# one checkout per run commit:
docker exec sst-repro-624 sh -c 'cd /work/swift-state-tree && git worktree add --detach /work/run-<commit> <commit>'
```

`network-impairment-2026-11` ran with `CAP_NET_ADMIN` and `CAP_SYS_ADMIN`: add `--cap-add NET_ADMIN --cap-add SYS_ADMIN` to `docker run` for it. The pinning, sysctls and host procedure of each run are in the topic's README; the container doesn't set them.

On 2026-11-28 this container built `75222b87eb008b1ad94e99d7ae96b83528c9d0a4` (release) and ran `recomputation-cost`'s smoke sweep (the command in its README) to completion, recording Swift 6.2.4 and a clean tree. A smoke sweep's values aren't results, and `regenerate.py` refuses them.

### Toolchain per topic

| Topic | Recorded toolchain | Run in the container |
|---|---|---|
| entity-delta-baseline | Swift 6.2.4, Node v24.22.2; the records name no image | `docker exec sst-repro-624 sh -c 'cd /work/run-75222b87eb008b1ad94e99d7ae96b83528c9d0a4/deep-research/entity-delta-baseline && bash run.sh'` |
| external-input-failure | Swift 6.2.4 in `swift:6.2.4-noble`, Node v24.22.2, Python 3.12.3 | `docker exec sst-repro-624 sh -c 'cd /work/run-022d8fdbca966f8df56f1fc86d29421b154ce7a0/deep-research/external-input-failure && bash run.sh'` |
| multiroom-load-2026-02 | WSL2, Swift 6.2.3, no container recorded | not reproduced by the container |
| multiroom-load-2026-11 | Swift 6.2.4 in `swift:6.2.4-noble`, Node v24.22.2 (every `toolchain.txt` and envelope) | `docker exec sst-repro-624 sh -c 'cd /work/run-695fe86cb985752293dc184ff4d650b0689d90c2/deep-research/multiroom-load-2026-11 && bash run.sh'` |
| multiroom-load-2026-11-server-ab | Swift 6.2.4 in `swift:6.2.4-noble` for both servers, Node v24.22.2 (every `toolchain.txt`) | both servers are built in the container, one checkout each (`/work/run-b629861fdf18e1a0621d85cde56e0e9d93ffec57`, `/work/run-ee8a407a4c0697afbd401d01f843aa09f4aafb72`); the load client is ws-loadtest at `9b41c5a91c98dee213771b3174073beb798e9569`, run as the README describes |
| network-impairment-2026-11 | Swift 6.2.4 in `swift:6.2.4-noble`, Node v24.22.2 | with the capabilities above: `docker exec sst-repro-624 sh -c 'cd /work/run-48962faea5bb47044620a5ee0e41505c6d9e77c1/deep-research/network-impairment-2026-11 && bash run.sh'` |
| recomputation-cost | Swift 6.2.4 in `swift:6.2.4-noble` | `docker exec sst-repro-624 sh -c 'cd /work/run-75222b87eb008b1ad94e99d7ae96b83528c9d0a4/deep-research/recomputation-cost && bash run.sh'` |
| replay-scale-fp-perturbation | mixed, see below | `results/perturb-3.1/` and `results/batch-*-x86_64.json` only: `docker exec sst-repro-624 sh -c 'cd /work/run-022d8fdbca966f8df56f1fc86d29421b154ce7a0/deep-research/replay-scale-fp-perturbation && bash crossarch-verify.sh'` |
| single-room-entity-scaling | mixed, see below | current record only: `docker exec sst-repro-624 sh -c 'cd /work/run-75222b87eb008b1ad94e99d7ae96b83528c9d0a4/deep-research/single-room-entity-scaling && bash run.sh'` |
| snapshot-baseline | mixed, see below | current record only: `docker exec sst-repro-624 sh -c 'cd /work/run-75222b87eb008b1ad94e99d7ae96b83528c9d0a4/deep-research/snapshot-baseline && bash run.sh'` |
| visibility | Swift 6.2.4, Node v24.22.2; the records name no image | `docker exec sst-repro-624 sh -c 'cd /work/run-75222b87eb008b1ad94e99d7ae96b83528c9d0a4/deep-research/visibility && bash run.sh'` |
| wire-ablation-2026-11 | Swift 6.2.4, Node v24.22.2; the records name no image | `docker exec sst-repro-624 sh -c 'cd /work/run-6f3783aadc34ea2390e2fe8575ad9591b756935c/deep-research/wire-ablation-2026-11 && bash run.sh'` |

Each script's options (cells, sweeps, CPU pinning) are in the topic's README.

### Topics with more than one toolchain

- **replay-scale-fp-perturbation**
  - `results/perturb-3.1/` (41 files) and `results/batch-2.5-x86_64.json`, `batch-3.0-x86_64.json`, `batch-3.1-x86_64.json`: Swift 6.2.4, AMD Ryzen 5 7600X, Docker `swift:6.2.4-noble`.
  - `results/crossarch-x86_64.json`: Swift 6.2.3, AMD Ryzen 5 7600X, WSL2 (Ubuntu), no container recorded; not reproduced by the container.
  - `results/rec-*.json` (41 files) and `results/perturb-s*-*.json` (30 files): Apple Swift 6.3.2, Apple M2; macOS host; not reproduced by the container.
  - `results/batch-2.5-arm64.json`, `batch-3.1-arm64.json`, `crossverify-3.1-arm64.json`: Apple Swift 6.4.2, Apple M2; macOS host; not reproduced by the container.
- **single-room-entity-scaling**
  - `results/` (current record, `75222b87`): Swift 6.2.4.
  - `results/pre-refreeze/` and `raw/`: Apple Swift 6.3.2; macOS host; not reproduced by the container.
- **snapshot-baseline**
  - `results/*-rep<N>.json` (current record, `75222b87`): Swift 6.2.4, AMD Ryzen 5 7600X.
  - The other files in `results/` and `raw/` (pre-refreeze record): Apple Swift 6.3.2, Apple M2; macOS host; not reproduced by the container.

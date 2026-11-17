# Replay verification at scale + FP perturbation sensitivity

## Question

(A) 大規模重播驗證（數十段錄音、上萬 ticks）下，逐 tick state-hash 比對是否維持 0 mismatch？
(B) 在重播中注入浮點／定點擾動時，hash 驗證能否偵測、偵測延遲幾個 tick？

> 名詞：遊戲狀態的座標一律是 `SwiftStateTreeDeterministicMath` 的定點包裝型別
> （`Position2`/`IVec2`，內部 `Int32`，scale 1000）——使用者不直接持有 float 座標，
> `IVec2(x: Float, y: Float)` 在建構時即量化，之後的座標運算全為整數/定點。
> **LSB = 定點表示的最小刻度（量化步長），1 LSB = 整數 +1 = 0.001 世界座標——不是浮點
> 的最小單位（ULP）**；狀態的任何改變至少 1 LSB。Float 僅出現在邊界（config 常數、事件
> 輸入、速度參數），本實驗的 float 擾動即注入於此邊界（量化前）。
> **浮點擾動** = 在量化前對 Float 輸入（移速）加極小偏移，模擬跨平台浮點捨入差異；
> **定點擾動** = 直接對量化後的整數座標加 N 個 LSB，模擬真正改變狀態的最小誤差。

## Environment

以下是原始紀錄（Part A／B，`d23d66d`，2026-08-31）的環境；之後各次重驗的機器、commit 與 toolchain 寫在各自的表中。

- date: 2026-08-31
- git_sha: `d23d66d`（`experiment/replay-scale-fp-perturbation` branch；含 `--record` 模式、擾動 hook、與確定性迭代修正）
- swift_version: Apple Swift 6.3.2, build_config: release（此為 2026-08-31 的原始紀錄；format 2.4/2.5 的 arm64 批次為 Apple Swift 6.4.2）
- host: Apple M2, macOS（8 cores, 16 GB）, arm64；跨架構重驗首次於 AMD Ryzen 5 7600X / WSL2 Ubuntu / Swift 6.2.3（x86_64）執行，見 Results 末表；record format 2.4/2.5 由兩台機器各自錄製與重驗（arm64 / Apple Swift 6.4.2；x86_64 / `swift:6.2.4-noble` 容器），3.0 只在 x86_64 執行；3.1 先在 x86_64 錄製，2026-11-17 在 arm64（Apple M2，macOS 27.2.1，Apple Swift 6.4.2）以同一 commit 再錄製並交叉重驗，見 Cross-architecture at record format 3.1 節

## Command(s)

```bash
cd Examples/GameDemo && swift build -c release
BIN=.build/release/ReevaluationRunner

# Part A: record + verify, seeds 1..30
$BIN --record --output s<N>.json --seed-id <N> --ticks 1200
$BIN --input s<N>.json --verify          # exit 0 = hashes match ground truth AND run1 == run2

# Part B: perturbed replay (recordings stay clean; the hook only affects this replay)
HERO_PERTURB_TICK=600 HERO_PERTURB_MODE=<float|fixed> HERO_PERTURB_EPS=<eps> \
  $BIN --input s<N>.json --verify
```

- `--record`：in-process live keeper，5 玩家 join、每 20 ticks 每人注入一個確定性 `MoveTo`
  client event、1,200 ticks（~60 s @20 Hz），錄下 inputs 與逐 tick state hash。rngSeed 由
  landID（`hero-defense:batch-<N>`）派生，每個 seed 是不同的一局。
- 擾動 hook 作用在 `MovementSystem.updatePlayerMovement`：`float` 模式在定點量化前對 Float
  moveSpeed 加 eps；`fixed` 模式在量化後對 x 座標加 eps 個 LSB（1 LSB = 0.001 world units）。
- 設計文件：`Notes/plans/2026-08-31-replay-scale-fp-perturbation-experiment-design.md`。

## Parameter matrix

| Part | 軸 | 值 | 固定 |
|---|---|---|---|
| A 核心 | seed | 1–30 | 1,200 ticks、5 players、MoveTo every 20 ticks |
| A 變體 | players | 2（seeds 101–103）、10（seeds 111–113） | 1,200 ticks、cadence 20 |
| A 變體 | MoveTo cadence | every 5 ticks（seeds 121–123） | 1,200 ticks、5 players |
| A 長程 | ticks | 12,000（~10 分鐘；seeds 201–202） | 5 players、cadence 20 |
| B | 擾動 | float 1e-7 / fixed +1 LSB / fixed +1000 LSB | perturb tick = 600，seeds 1–10 |
| B（3.1） | 擾動 | 同上，另加 serveronly +1（`nextTurretID`，runner `dc6f85e7`） | perturb tick = 600，3.1 批次的 seeds 1–10 |

## Results

### Part A — replay verification at scale (aggregate)

| recordings | total ticks | total actions | total client events | hash mismatches | verified vs recorded | run1 == run2 |
|---:|---:|---:|---:|---:|---:|---:|
| 41 | 70800 | 0 | 20760 | 0 | 41/41 | 41/41 |

### Part A — per recording

| seed | players | move every | ticks | actions | client events | hash mismatches | verified |
|---:|---:|---:|---:|---:|---:|---:|---|
| 101 | 2 | 20 | 1200 | 0 | 120 | 0 | yes |
| 102 | 2 | 20 | 1200 | 0 | 120 | 0 | yes |
| 103 | 2 | 20 | 1200 | 0 | 120 | 0 | yes |
| 121 | 5 | 5 | 1200 | 0 | 1200 | 0 | yes |
| 122 | 5 | 5 | 1200 | 0 | 1200 | 0 | yes |
| 123 | 5 | 5 | 1200 | 0 | 1200 | 0 | yes |
| 1 | 5 | 20 | 1200 | 0 | 300 | 0 | yes |
| 2 | 5 | 20 | 1200 | 0 | 300 | 0 | yes |
| 3 | 5 | 20 | 1200 | 0 | 300 | 0 | yes |
| 4 | 5 | 20 | 1200 | 0 | 300 | 0 | yes |
| 5 | 5 | 20 | 1200 | 0 | 300 | 0 | yes |
| 6 | 5 | 20 | 1200 | 0 | 300 | 0 | yes |
| 7 | 5 | 20 | 1200 | 0 | 300 | 0 | yes |
| 8 | 5 | 20 | 1200 | 0 | 300 | 0 | yes |
| 9 | 5 | 20 | 1200 | 0 | 300 | 0 | yes |
| 10 | 5 | 20 | 1200 | 0 | 300 | 0 | yes |
| 11 | 5 | 20 | 1200 | 0 | 300 | 0 | yes |
| 12 | 5 | 20 | 1200 | 0 | 300 | 0 | yes |
| 13 | 5 | 20 | 1200 | 0 | 300 | 0 | yes |
| 14 | 5 | 20 | 1200 | 0 | 300 | 0 | yes |
| 15 | 5 | 20 | 1200 | 0 | 300 | 0 | yes |
| 16 | 5 | 20 | 1200 | 0 | 300 | 0 | yes |
| 17 | 5 | 20 | 1200 | 0 | 300 | 0 | yes |
| 18 | 5 | 20 | 1200 | 0 | 300 | 0 | yes |
| 19 | 5 | 20 | 1200 | 0 | 300 | 0 | yes |
| 20 | 5 | 20 | 1200 | 0 | 300 | 0 | yes |
| 21 | 5 | 20 | 1200 | 0 | 300 | 0 | yes |
| 22 | 5 | 20 | 1200 | 0 | 300 | 0 | yes |
| 23 | 5 | 20 | 1200 | 0 | 300 | 0 | yes |
| 24 | 5 | 20 | 1200 | 0 | 300 | 0 | yes |
| 25 | 5 | 20 | 1200 | 0 | 300 | 0 | yes |
| 26 | 5 | 20 | 1200 | 0 | 300 | 0 | yes |
| 27 | 5 | 20 | 1200 | 0 | 300 | 0 | yes |
| 28 | 5 | 20 | 1200 | 0 | 300 | 0 | yes |
| 29 | 5 | 20 | 1200 | 0 | 300 | 0 | yes |
| 30 | 5 | 20 | 1200 | 0 | 300 | 0 | yes |
| 111 | 10 | 20 | 1200 | 0 | 600 | 0 | yes |
| 112 | 10 | 20 | 1200 | 0 | 600 | 0 | yes |
| 113 | 10 | 20 | 1200 | 0 | 600 | 0 | yes |
| 201 | 5 | 20 | 12000 | 0 | 3000 | 0 | yes |
| 202 | 5 | 20 | 12000 | 0 | 3000 | 0 | yes |

### Part B — perturbation sensitivity (perturb at tick 600, 10 recordings each)

| mode | eps | detected | detection latency (ticks) |
|---|---|---:|---|
| float +1e-7 (sub-LSB, pre-quantization) | 1e-07 | 0/10 | — |
| fixed +1 LSB (0.001 world units) | 1 | 10/10 | min 0 / max 0 |
| fixed +1000 LSB (1.0 world unit) | 1000 | 10/10 | min 0 / max 0 |

### Cross-architecture verification — replay the arm64-recorded batch elsewhere

| arch | host | swift | recordings | pass | fail |
|---|---|---|---:|---:|---:|
| x86_64 | AMD Ryzen 5 7600X 6-Core Processor, WSL2 (Ubuntu) | 6.2.3 | 41 | 41 | 0 |

## Re-measurement at record format 2.5

| machine | arch | commit | tree | swift | build | recordings | verified vs recorded | run1 == run2 | second recording byte-identical | tick mismatches | ticks | client events | actions |
|---|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Apple M2, macOS 27.2 | arm64 | `0d213f2f` | not recorded | Apple Swift 6.4.2 | release | 41 | 41/41 | 41/41 | not recorded | 0 | 70,800 | 20,760 | 0 |
| AMD Ryzen 5 7600X, Linux (WSL2, Docker swift:6.2.4-noble) | x86_64 | `6e5cb141` | not recorded | Swift 6.2.4 | release | 41 | 41/41 | 41/41 | not recorded | 0 | 70,800 | 20,760 | 0 |

## Re-measurement at record format 3.0

| machine | arch | commit | tree | swift | build | recordings | verified vs recorded | run1 == run2 | second recording byte-identical | tick mismatches | ticks | client events | actions |
|---|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| AMD Ryzen 5 7600X, Linux (WSL2, Docker swift:6.2.4-noble) | x86_64 | `986097b7` | clean | Swift 6.2.4 | release | 41 | 41/41 | 41/41 | 40/41 | 0 | 70,800 | 20,760 | 0 |


## Re-measurement at record format 3.1

| machine | arch | commit | tree | swift | build | recordings | verified vs recorded | run1 == run2 | second recording byte-identical | tick mismatches | ticks | client events | actions |
|---|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Apple M2, macOS 27.2.1 | arm64 | `022d8fdb` | clean | Apple Swift 6.4.2 | release | 41 | 41/41 | 41/41 | 41/41 | 0 | 70,800 | 20,760 | 0 |
| AMD Ryzen 5 7600X, Linux (WSL2, Docker swift:6.2.4-noble) | x86_64 | `022d8fdb` | clean | Swift 6.2.4 | release | 41 | 41/41 | 41/41 | 41/41 | 0 | 70,800 | 20,760 | 0 |

## Cross-architecture at record format 3.1

On 2026-11-17 the 3.1 batch was recorded again on an Apple M2 (arm64, macOS 27.2.1, Apple Swift 6.4.2). It used the same 41 recordings, `scripts/run-batch.sh` with `TWICE=1`, and a clean checkout of `022d8fdb` (`source.json`: clean before the build and after the last seed). It is compared with the 2026-11-09 x86_64 batch (AMD Ryzen 5 7600X, Linux, Swift 6.2.4). Both batches are rows of the table above (`results/batch-3.1-arm64.json`, `results/batch-3.1-x86_64.json`).

- **Cross-verify, the replay claim.** The arm64 runner (release, `022d8fdb`) replayed the 41 x86_64 recordings with `--verify`. All 41 exited 0 with both "Verified state hashes" lines (`results/crossverify-3.1-arm64.json`, written by `scripts/crossverify_collect.py`). The other direction, the x86_64 runner replaying the arm64 recordings, has not been run yet. Those recordings are byte-identical to the x86_64 batch's own, which that runner verified 41/41 in its batch.
- **Bytes.** 41/41 recordings are byte-identical across the two machines. The arm64 batch's SHA256SUMS list is byte-identical to `results/batch-3.1-SHA256SUMS.txt`, so both batches name that one file.
- **Content.** 41/41 recordings are identical (the sha256 of the `--convert` JSON view). No recording on either machine has a tick split into several turn records (#327), the reason two recordings can differ in bytes with the same content.
- **The same machine twice.** Each machine's second recording is byte-identical to its first, 41/41 on each (the table above).
- **Scope.** The comparison crosses the architecture, the OS (macOS against Linux) and the compiler version (Apple Swift 6.4.2 against Swift 6.2.4) together. The match holds across all three at once; it doesn't separate them. Sync outputs aren't compared: a 3.1 record has no sync stream, and the runner reports "Sync Output: skipped".

`regenerate.py` writes the three tables below and `--check` gates them. Both 3.1 batches must be at one commit, and the cross-verify must replay the other machine's batch recordings, matched by seed and sha256.

| runner | host | swift | commit | runner sha256 | recordings recorded on | recordings | exit 0 with both verification lines |
|---|---|---|---|---|---|---:|---:|
| arm64 | Apple M2, macOS 27.2.1 | Apple Swift version 6.4.2 | `022d8fdb` | `b7b8f0fe430253d5ba1341a4c147d8c1722624eac6bd8b96b07b2431c983d667` | x86_64 | 41 | 41/41 |

| comparison (arm64 vs x86_64) | recordings |
|---|---:|
| byte-identical (file sha256) | 41/41 |
| content-identical (sha256 of the `--convert` JSON view) | 41/41 |
| with split ticks, arm64 / x86_64 | 0 / 0 |

| seed | players | move every | ticks | sha256 (arm64) | sha256 (x86_64) | bytes | content |
|---:|---:|---:|---:|---|---|---|---|
| 1 | 5 | 20 | 1200 | `e077a39dabb8` | `e077a39dabb8` | same | same |
| 2 | 5 | 20 | 1200 | `464482a0f490` | `464482a0f490` | same | same |
| 3 | 5 | 20 | 1200 | `1cecc5264207` | `1cecc5264207` | same | same |
| 4 | 5 | 20 | 1200 | `8ba6f8fd6863` | `8ba6f8fd6863` | same | same |
| 5 | 5 | 20 | 1200 | `6c8b90e4d2f9` | `6c8b90e4d2f9` | same | same |
| 6 | 5 | 20 | 1200 | `672af6cc2a91` | `672af6cc2a91` | same | same |
| 7 | 5 | 20 | 1200 | `ecc145290cab` | `ecc145290cab` | same | same |
| 8 | 5 | 20 | 1200 | `80aa0397a3c6` | `80aa0397a3c6` | same | same |
| 9 | 5 | 20 | 1200 | `55e7cb21b1f7` | `55e7cb21b1f7` | same | same |
| 10 | 5 | 20 | 1200 | `d988fb02e1fd` | `d988fb02e1fd` | same | same |
| 11 | 5 | 20 | 1200 | `3e9fb14fd0ae` | `3e9fb14fd0ae` | same | same |
| 12 | 5 | 20 | 1200 | `fedfb377666f` | `fedfb377666f` | same | same |
| 13 | 5 | 20 | 1200 | `e875e6add343` | `e875e6add343` | same | same |
| 14 | 5 | 20 | 1200 | `b4bb4765c70d` | `b4bb4765c70d` | same | same |
| 15 | 5 | 20 | 1200 | `ba55c023f0f6` | `ba55c023f0f6` | same | same |
| 16 | 5 | 20 | 1200 | `cc57830dbb7f` | `cc57830dbb7f` | same | same |
| 17 | 5 | 20 | 1200 | `171ec2faa4a4` | `171ec2faa4a4` | same | same |
| 18 | 5 | 20 | 1200 | `3b90b82dc1ca` | `3b90b82dc1ca` | same | same |
| 19 | 5 | 20 | 1200 | `6c82118f2ba0` | `6c82118f2ba0` | same | same |
| 20 | 5 | 20 | 1200 | `aeaa175d2c2f` | `aeaa175d2c2f` | same | same |
| 21 | 5 | 20 | 1200 | `fb527f8c334b` | `fb527f8c334b` | same | same |
| 22 | 5 | 20 | 1200 | `9c86e70017e1` | `9c86e70017e1` | same | same |
| 23 | 5 | 20 | 1200 | `7d42ff84cb30` | `7d42ff84cb30` | same | same |
| 24 | 5 | 20 | 1200 | `601fd43f9290` | `601fd43f9290` | same | same |
| 25 | 5 | 20 | 1200 | `0019eba814fa` | `0019eba814fa` | same | same |
| 26 | 5 | 20 | 1200 | `31ceb18f015c` | `31ceb18f015c` | same | same |
| 27 | 5 | 20 | 1200 | `4472ea0f43c7` | `4472ea0f43c7` | same | same |
| 28 | 5 | 20 | 1200 | `81d043d280d2` | `81d043d280d2` | same | same |
| 29 | 5 | 20 | 1200 | `cb6f22e6f64c` | `cb6f22e6f64c` | same | same |
| 30 | 5 | 20 | 1200 | `6a78ea9aa3ef` | `6a78ea9aa3ef` | same | same |
| 101 | 2 | 20 | 1200 | `42687a61d4b8` | `42687a61d4b8` | same | same |
| 102 | 2 | 20 | 1200 | `a17c5eedfd2f` | `a17c5eedfd2f` | same | same |
| 103 | 2 | 20 | 1200 | `96c1bce996c7` | `96c1bce996c7` | same | same |
| 111 | 10 | 20 | 1200 | `3c3a3497ffee` | `3c3a3497ffee` | same | same |
| 112 | 10 | 20 | 1200 | `9ec19b296b62` | `9ec19b296b62` | same | same |
| 113 | 10 | 20 | 1200 | `9c23a9bbd09d` | `9c23a9bbd09d` | same | same |
| 121 | 5 | 5 | 1200 | `40d086db7071` | `40d086db7071` | same | same |
| 122 | 5 | 5 | 1200 | `15c4579039cc` | `15c4579039cc` | same | same |
| 123 | 5 | 5 | 1200 | `e948c5db8447` | `e948c5db8447` | same | same |
| 201 | 5 | 20 | 12000 | `b180d034617f` | `b180d034617f` | same | same |
| 202 | 5 | 20 | 12000 | `d12be6ce4b48` | `d12be6ce4b48` | same | same |

## Part B at record format 3.1 (full-state hash)

Part B above (2026-08-31) hashed the broadcast view of the state (`snapshot(for: nil)`). Since record format 2.4 the per-tick hash covers every `@Sync` field, server-only fields included, and no `@Internal` property. This re-run repeats Part B with that hash and adds one cell that perturbs a server-only field.

- **Recordings:** the 3.1 batch's seeds 1–10 (5 players, a MoveTo every 20 ticks, 1,200 ticks each, a state hash on every tick): the files that batch recorded, not new recordings. Each file's sha256 equals its line in `results/batch-3.1-SHA256SUMS.txt`, which `regenerate.py --check` compares.
- **Runners:** release builds of `ReevaluationRunner`. The three original cells ran at `022d8fdb`, the 3.1 batch's commit. The server-only cell ran at `dc6f85e7` (tag `perturb-serveronly-runner-2026-11`), one commit on `022d8fdb` that changes only `Examples/GameDemo/Sources/GameContent/HeroDefenseLand.swift` and `Systems/MovementSystem.swift` (`git diff --stat 022d8fdb dc6f85e7 -- Sources Package.swift Package.resolved` prints nothing). It adds `HERO_PERTURB_MODE=serveronly`: at `HERO_PERTURB_TICK` it adds the integer `HERO_PERTURB_EPS` to `HeroDefenseState.nextTurretID`, a `@Sync(.serverOnly)` counter that no client receives. As in every cell, the hook acts only in the replay process; the recordings stay those of `022d8fdb`.
- **Machine:** AMD Ryzen 5 7600X, Linux (WSL2, Docker `swift:6.2.4-noble`), Swift 6.2.4, 2026-11-17.

```bash
# Control, each runner and recording: no perturbation
env -u HERO_PERTURB_TICK -u HERO_PERTURB_MODE -u HERO_PERTURB_EPS ReevaluationRunner --input s<N>.sstr --verify
# The original cells, runner at 022d8fdb
HERO_PERTURB_TICK=600 HERO_PERTURB_MODE=float HERO_PERTURB_EPS=1e-07  ReevaluationRunner --input s<N>.sstr --verify
HERO_PERTURB_TICK=600 HERO_PERTURB_MODE=fixed HERO_PERTURB_EPS=1.0    ReevaluationRunner --input s<N>.sstr --verify
HERO_PERTURB_TICK=600 HERO_PERTURB_MODE=fixed HERO_PERTURB_EPS=1000.0 ReevaluationRunner --input s<N>.sstr --verify
# The server-only cell, runner at dc6f85e7
HERO_PERTURB_TICK=600 HERO_PERTURB_MODE=serveronly HERO_PERTURB_EPS=1 ReevaluationRunner --input s<N>.sstr --verify
```

Each run is its own process. A run is **detected** when `--verify` exits 5 with "Verification failed: mismatched ticks vs recorded=<n>": the first mismatching tick is the first `tick` line it prints, the latency is that tick minus 600, and n is the number of mismatching ticks. A run is **not detected** when it exits 0 with both "Verified state hashes" lines (the computed hashes match the recorded ones, and two re-evaluation runs are identical). No run exited otherwise. `scripts/perturb_collect.py` reads the logs into `results/perturb-3.1/`, and `regenerate.py` builds the tables below from those files.

Summary, in the shape of the 2026-08-31 table plus the mismatch ticks and the runner:

| mode | eps | runner | detected | detection latency (ticks) min / max | mismatch ticks min / max |
|---|---|---|---:|---|---|
| float | 1e-07 | `022d8fdb` | 0/10 | — | — |
| fixed | 1.0 | `022d8fdb` | 10/10 | 0 / 0 | 46 / 46 |
| fixed | 1000.0 | `022d8fdb` | 10/10 | 0 / 0 | 98 / 600 |
| serveronly | 1 | `dc6f85e7` | 10/10 | 0 / 0 | 600 / 600 |

Controls: with the three variables unset, both runners verify all ten recordings.

| runner | runner sha256 | recordings | exit 0 with both verification lines |
|---|---|---:|---:|
| `022d8fdb` | `ccff7d190b437a84009f3ffc986f1e7b52663e8fd0bd5fa775758dcf33fbb306` | 10 | 10/10 |
| `dc6f85e7` | `cda7802d436400c2321c0f1fe15dd80ad9456a41f3b86f23c46e41f1a849206d` | 10 | 10/10 |

- **float 1e-07: 0/10.** In none of the ten recordings did a hashed field change: the offset, added to the Float move speed before quantization, was absorbed by quantization. The mechanism, in the code at `022d8fdb`:
  - The hook adds eps to `moveSpeed` (`Examples/GameDemo/Sources/GameContent/Systems/MovementSystem.swift:60–63`). That speed is the constant 1.0: the parameter's default (`MovementSystem.swift:50`), since `HeroDefenseLand.swift:51` passes none.
  - It is used only as `moveTowards`' `maxDistance` (`MovementSystem.swift:78`), which `FixedPoint.quantize` turns into fixed point (`Sources/SwiftStateTreeDeterministicMath/Semantic/Semantic2.swift:219`): value × 1000, rounded to nearest (`Sources/SwiftStateTreeDeterministicMath/Core/FixedPoint.swift:122–128`).
  - In Float32, 1.0 + 1e-7 is 1.00000012, × 1000 is 1000.00012, and that rounds to 1000, the unperturbed value.
  - So the 0/10 is the absorption of an offset that sits about 0.5 LSB from either rounding boundary, the same in every recording whatever its seed. A player that has no target, or is within its arrival threshold, at tick 600 doesn't read the speed at all.
  - It doesn't show that an offset is absorbed when the value is near a rounding boundary, where it can quantize one LSB off (an LSB is the fixed-point step, 0.001 world units, not a float ULP). That is the size of change the fixed +1 cell injects.
- **fixed 1.0 and 1000.0 (+1 and +1000 LSB on a moving player's x): 10/10 at latency 0,** as on 2026-08-31. Absorption by quantization and detection by the hash are separate results: the float row says that the offset reached no hashed field, the fixed rows that a change which does reach one is detected on the tick it is made.
- **serveronly 1: 10/10 at latency 0,** every tick from 600 to 1,199 mismatching (600 ticks). The counter is in the full-state hash and not in the broadcast view. In these recordings it stays out of every broadcast field only because they place no turret: the counter is read only when a turret is placed, and the recordings carry only MoveTo events.

Every run:

| seed | mode | eps | runner | exit | detected | first mismatch tick | latency (ticks) | mismatch ticks |
|---:|---|---|---|---:|---|---:|---:|---:|
| 1 | float | 1e-07 | `022d8fdb` | 0 | no | — | — | — |
| 2 | float | 1e-07 | `022d8fdb` | 0 | no | — | — | — |
| 3 | float | 1e-07 | `022d8fdb` | 0 | no | — | — | — |
| 4 | float | 1e-07 | `022d8fdb` | 0 | no | — | — | — |
| 5 | float | 1e-07 | `022d8fdb` | 0 | no | — | — | — |
| 6 | float | 1e-07 | `022d8fdb` | 0 | no | — | — | — |
| 7 | float | 1e-07 | `022d8fdb` | 0 | no | — | — | — |
| 8 | float | 1e-07 | `022d8fdb` | 0 | no | — | — | — |
| 9 | float | 1e-07 | `022d8fdb` | 0 | no | — | — | — |
| 10 | float | 1e-07 | `022d8fdb` | 0 | no | — | — | — |
| 1 | fixed | 1.0 | `022d8fdb` | 5 | yes | 600 | 0 | 46 |
| 2 | fixed | 1.0 | `022d8fdb` | 5 | yes | 600 | 0 | 46 |
| 3 | fixed | 1.0 | `022d8fdb` | 5 | yes | 600 | 0 | 46 |
| 4 | fixed | 1.0 | `022d8fdb` | 5 | yes | 600 | 0 | 46 |
| 5 | fixed | 1.0 | `022d8fdb` | 5 | yes | 600 | 0 | 46 |
| 6 | fixed | 1.0 | `022d8fdb` | 5 | yes | 600 | 0 | 46 |
| 7 | fixed | 1.0 | `022d8fdb` | 5 | yes | 600 | 0 | 46 |
| 8 | fixed | 1.0 | `022d8fdb` | 5 | yes | 600 | 0 | 46 |
| 9 | fixed | 1.0 | `022d8fdb` | 5 | yes | 600 | 0 | 46 |
| 10 | fixed | 1.0 | `022d8fdb` | 5 | yes | 600 | 0 | 46 |
| 1 | fixed | 1000.0 | `022d8fdb` | 5 | yes | 600 | 0 | 100 |
| 2 | fixed | 1000.0 | `022d8fdb` | 5 | yes | 600 | 0 | 100 |
| 3 | fixed | 1000.0 | `022d8fdb` | 5 | yes | 600 | 0 | 135 |
| 4 | fixed | 1000.0 | `022d8fdb` | 5 | yes | 600 | 0 | 600 |
| 5 | fixed | 1000.0 | `022d8fdb` | 5 | yes | 600 | 0 | 100 |
| 6 | fixed | 1000.0 | `022d8fdb` | 5 | yes | 600 | 0 | 98 |
| 7 | fixed | 1000.0 | `022d8fdb` | 5 | yes | 600 | 0 | 294 |
| 8 | fixed | 1000.0 | `022d8fdb` | 5 | yes | 600 | 0 | 541 |
| 9 | fixed | 1000.0 | `022d8fdb` | 5 | yes | 600 | 0 | 100 |
| 10 | fixed | 1000.0 | `022d8fdb` | 5 | yes | 600 | 0 | 100 |
| 1 | serveronly | 1 | `dc6f85e7` | 5 | yes | 600 | 0 | 600 |
| 2 | serveronly | 1 | `dc6f85e7` | 5 | yes | 600 | 0 | 600 |
| 3 | serveronly | 1 | `dc6f85e7` | 5 | yes | 600 | 0 | 600 |
| 4 | serveronly | 1 | `dc6f85e7` | 5 | yes | 600 | 0 | 600 |
| 5 | serveronly | 1 | `dc6f85e7` | 5 | yes | 600 | 0 | 600 |
| 6 | serveronly | 1 | `dc6f85e7` | 5 | yes | 600 | 0 | 600 |
| 7 | serveronly | 1 | `dc6f85e7` | 5 | yes | 600 | 0 | 600 |
| 8 | serveronly | 1 | `dc6f85e7` | 5 | yes | 600 | 0 | 600 |
| 9 | serveronly | 1 | `dc6f85e7` | 5 | yes | 600 | 0 | 600 |
| 10 | serveronly | 1 | `dc6f85e7` | 5 | yes | 600 | 0 | 600 |

## Conclusion

41 段錄音共 **70,800 ticks**（核心 30×1,200 + 玩家數/注入節奏變體 9 段 + 兩段 12,000-tick 長程）
重播驗證 **0 hash mismatch**，且每段 run1 與 run2 完全一致。最新一次在 record format 3.1
（`022d8fdb`，x86_64，Swift 6.2.4）：41/41 verified vs recorded、41/41 run1 == run2、0 tick
mismatch。這是計數，不換算成 per-tick mismatch 機率的上界：同一段錄音內的 tick 不是獨立試驗。

擾動測試（Part B）最初是 2026-08-31 的紀錄（`d23d66d`，hash 為 broadcast view）；2026-11-17 在 record
format 3.1 以 full-state hash（涵蓋每個 `@Sync` 欄位，不含 `@Internal` 屬性）重跑，用的是 3.1 批次的
seeds 1–10，另加一格 server-only 欄位的擾動（[Part B at record format 3.1](#part-b-at-record-format-31-full-state-hash)）。
兩次結果相同：
- **量化吸收（觀察，非保證）**：次解析度的浮點擾動（1e-7，量化前，加在 moveSpeed）在兩次各 10 段錄音裡都
  0/10 被偵測，即沒有任何被 hash 的欄位改變。這是這些錄音裡觀察到的結果：落在捨入邊界附近的值，加上 1e-7
  後可能量化成差 1 LSB 的整數（LSB = 定點步長 0.001 世界座標，不是浮點 ULP）。
- **hash 偵測**：移動中玩家 x 座標 +1 與 +1000 LSB 的偏移 10/10 在注入當 tick（延遲 0）被逐 tick hash 比對
  暴露。量化吸收與 hash 偵測是兩個不同的結果：前者是偏移沒有寫進被 hash 的欄位，後者是寫進去的改變當拍被發現。
- **server-only 欄位**（只在 3.1 重跑）：`nextTurretID`（`@Sync(.serverOnly)`）+1，10/10 在注入當 tick 被偵測，
  之後每個 tick 都不符（600/600）。這個欄位不在 broadcast view 裡；在這些錄音中它沒有影響任何 broadcast 欄位，
  只是因為錄音裡沒有放置砲塔（這個計數只在放置砲塔時被讀取）。

此驗證屬 audit-time（重播稽核／CI）機制，非 runtime 監測。

跨架構：在 record format 2.4 與 2.5，兩台機器各自獨立錄製一批（arm64 / macOS / Apple Swift 6.4.2，
x86_64 / Linux / Swift 6.2.4），41 個 x86_64 檔與 arm64 檔逐檔 sha256 比對 41/41 位元相同，所以各機
驗證自己那批也同時驗證了另一批，同時跨 CPU 架構、作業系統與 toolchain 三軸。3.0 與 3.1 只在 x86_64 執行，所以跨機器的位元一致最後一次是在 2.5 顯示的。較早的一次重驗
（2026-09-12，`results/crossarch-x86_64.json`）把 arm64 錄音以 sha256 對帳搬到 x86_64（WSL2 Ubuntu /
Swift 6.2.3）重播，41/41 通過、0 mismatch。`E_t` 錄下後，δ 的重評估在這兩個平台之間不受錄製平台影響。

## Re-measurement at record format 2.4 (full-state hash, #180)

The runs above, and every record before format 2.4, hashed the **broadcast view** of the state
(`snapshot(for: nil)`). Server-only fields such as `MonsterState.pathProgress` (`Float`),
`players.*.lastFireTick` and `nextMonsterID` were not covered. From record format 2.4 (#185,
merge commit `f84892f`), the per-tick state hash covers the full state: every `@Sync` field at
every depth, whatever its policy, but not `@Internal` properties. Part A was re-recorded and
verified with that hash on 2026-11-06 at commit `2c9d2849` (the PR head that was merged).

**Matrix:** Part A as above, 41 recordings:
- seeds 1–30: 5 players, MoveTo every 20 ticks, 1,200 ticks;
- 101–103: 2 players;
- 111–113: 10 players;
- 121–123: MoveTo every 5 ticks;
- 201–202: 12,000 ticks.

Each was recorded with `ReevaluationRunner --record --seed-id <N> --players <P> --move-every <M> --ticks <T>` and checked with `--input s<N>.json --verify`.

| machine | arch | swift | build | recordings | verified | tick mismatches | ticks | client events | actions |
|---|---|---|---|---:|---:|---:|---:|---:|---:|
| Apple M2, macOS | arm64 | Apple Swift 6.4.2 | release | 41 | 41 | 0 | 70,800 | 20,760 | 0 |
| AMD Ryzen 5 7600X, `swift:6.2.4-noble` container | x86_64 | 6.2.4 | release | 41 | 41 | 0 | 70,800 | 20,760 | 0 |

Every tick carries a full-state hash (70,800 of 70,800 on each machine). The totals equal the
original Part A.

**Cross-architecture and cross-toolchain identity:**
- The two batches were recorded independently, one on each machine.
- The records are byte-deterministic: sorted-keys JSON, a fixed `createdAt` in `--record`, and no host fields.
- All 41 x86_64 files are byte-identical to the arm64 files, by per-file sha256, 41/41 equal.
- The per-file list is `results/batch-2.4-SHA256SUMS.txt`. The list itself has sha256 `8cd1c29ead1b67afdf4cde21e6618ffd8ebc4a15f98c2164f7c0b0582a6a2ed5`, on both machines.

Each machine's verification of its own batch therefore also verifies the other's, in both directions. The comparison crosses three things at once:
- CPU architecture: arm64 and x86_64;
- operating system: macOS and Linux;
- toolchain: Apple Swift 6.4.2 and Swift 6.2.4.

With the full-state hash this covers the server-only `Float` `pathProgress`. In Hero Defense it is computed from integer square roots, dequantized, then one IEEE division and `min`, with no library math.

Part B (perturbation) was not re-run at 2.4; it was re-run at record format 3.1 ([Part B at record format 3.1](#part-b-at-record-format-31-full-state-hash)).

## Record format 2.5: what changed and how it was verified

Record format 2.5 (#154, merge commit `0d213f2`) writes `PlayerID`, `ClientID`, `SessionID` and
`LandID` as strings, and readers reject every older record. So the 2.4 batch above can no longer be
replayed by the current build. Part A was re-recorded and verified at `0d213f2` on 2026-11-06, with
the same matrix and commands as the 2.4 batch: 41 recordings, seeds 1–30, 101–103, 111–113,
121–123 and 201–202.

The batch table is the one under "Re-measurement at record format 2.5" above (`regenerate.py` writes it).

Every tick carries a full-state hash (70,800 of 70,800) on both machines. The totals equal the
2.4 batch.

- `verified vs recorded`: the replayed hashes match the recorded ones. `run1 == run2`: two
  re-evaluation runs give identical hashes. `--verify` checks both and exited 0 for all 41.
- Byte determinism: recording the whole batch a second time on the same machine gave 41/41
  byte-identical files.
- The per-file list is `results/batch-2.5-SHA256SUMS.txt` (its own sha256
  `292ad9faf53c5ed1fa3f441b586f5dfc3a505f35488e072049c32b0d3b6decb1`). The per-recording data is
  `results/batch-2.5-arm64.json`, and `regenerate.py --check` checks the table above against it.
  `results/batch-2.5-x86_64.json` holds the x86_64 run's metadata and totals only (its
  per-recording data stays on that machine and equals the arm64 file field for field, apart from
  the metadata); `--check` checks that its totals equal the arm64 file's and that both name the
  same SHA256SUMS hash.
- The files differ from the 2.4 batch: at least the record version changes.
- To reproduce: `scripts/run-batch.sh <repo-root> <out-dir>` builds `ReevaluationRunner` in release
  in `Examples/GameDemo` from the recorded tree, then records and verifies the 41, and
  `scripts/summarize.py <out-dir> <host> <swift> <arch> <json-out> <sums-out>` writes the
  batch JSON and the SHA256SUMS list. The commit is the batch's own: `run-batch.sh` writes
  `<out-dir>/source.json` (`git rev-parse HEAD` and whether `git status --porcelain` was empty)
  before the build, `built` after it, and both again after the last seed. `summarize.py` takes the
  commit from it and refuses a batch that it didn't build, a dirty tree, or a commit or tree that
  changed while it ran. An `<out-dir>` inside the checkout must be gitignored (refused otherwise). The 2.5 batch was recorded by an earlier version of the script
  (`s<N>.json`); today's checkout writes record format 3.x (`.sstr`, #245), so a rerun is a new batch:
  `results/batch-<format>-<arch>.json` and `results/batch-<format>-SHA256SUMS.txt`, with the format
  read from the verify logs. `run-batch.sh` now also records each seed a second time (`TWICE=1`,
  the default) and compares the two by content: the sha256 of each one's JSON view
  (`ReevaluationRunner --convert`): the two recordings are identical as the reader merges them,
  the JSON view replay's frames come from (the metadata and every tick's merged frame: inputs,
  server events, state hash, watermarks, sync outputs and markers, initialize). From format 3.0
  on, the bytes can differ with the same content: the recorder's timer flush can split a tick into
  two turn records at a wall-time point (#327). The view doesn't keep the turn split, the footer's
  counts, an earlier value of a scalar overwritten later in the same tick, or a number's encoded
  MessagePack type (int or float of the same value). The file sha256s stay in
  `summary.tsv` and the SHA256SUMS list as the archive's checksums; each recording also carries
  `second_recording_bytes_identical` and `split_ticks`, both files' ticks with more than one turn
  record (`scripts/turns.py`), as the reason for a byte difference. The 2.4 and 2.5 batches,
  encoded whole at save, were compared by bytes. The script hashes with `sha256sum`, `shasum` or
  Python, and takes
  `SEEDS="<n> ..."` (a smoke) and `DRY_RUN=1`. `regenerate.py` renders one
  `## Re-measurement at record format <format>` table per format and `--check` refuses a 3.x batch
  that isn't all 41 recordings with zero record and verify exits and second recordings identical in
  content,
  or that doesn't carry the clean commit from `source.json`.
  `python3 test_topic.py` checks the batch path against a stand-in runner (no build needed).
- The x86_64 batch ran at `6e5cb14`, whose `Sources` and `Examples` equal `0d213f2` (`git diff 0d213f2 6e5cb14 -- Sources Examples` is empty), in Docker `swift:6.2.4-noble` on WSL2 (kernel 6.18.54.1-microsoft-standard-WSL2, `swift-6.2.4-RELEASE`, `x86_64-unknown-linux-gnu`).

**Cross-architecture and cross-toolchain identity:**
- The two batches were recorded independently, one on each machine.
- All 41 x86_64 files are byte-identical to the arm64 files, by per-file sha256, 41/41 equal: the x86_64 SHA256SUMS list is byte-identical to `results/batch-2.5-SHA256SUMS.txt` (sha256 `292ad9faf53c5ed1fa3f441b586f5dfc3a505f35488e072049c32b0d3b6decb1` on both machines).

Each machine's verification of its own batch therefore also verifies the other's, in both directions. The comparison crosses three things at once:
- CPU architecture: arm64 and x86_64;
- operating system: macOS and Linux;
- toolchain: Apple Swift 6.4.2 and Swift 6.2.4.

## Caveats

- **本實驗過程中發現並修正了一個真實的決定性 bug**：hero-defense tick handler 與最近目標選擇
  依賴 Dictionary 迭代順序，1,200-tick 規模下 28/30 段重播發散（短錄音從未觸發）。修正為
  sorted-key 迭代與 lowest-id tie-break（commit `d23d66d`）後才有上表結果。此發現本身即為
  規模化驗證的價值證據，詳見設計文件 Findings。
- **重播的 server event sequence 編號與錄製不同**（重播不推進共用序號計數器，已知缺口）：
  Runner 以內容級比對（tickId/type/payload/target）複核，純序號差異降為明示警告；core 修復
  為後續工作。本表所有 record 的事件內容比對皆通過。
  - Update 2026-11-04: fixed by #72 for records with sequence watermarks (recorded from then on);
    those are verified exactly, including `sequence`. The records behind the table above predate
    the fix and carry no watermarks, so they still go through the content-only re-check.
- 原始紀錄（2026-08-31）的錄製與重播同為 arm64/macOS；跨架構（arm64→x86_64）證據見 Results 末表
  與 record format 2.4、2.5 各節（3.0、3.1 只在 x86_64 執行）。
- 擾動作用於當 tick 所有移動中的玩家（非單一玩家）；latency 以「首個 mismatch tick − 600」計。
- 錄音檔（每段 ~1200 ticks）未入 repo：由 `--record --seed-id <N>` 可決定性重建。
- 已變動軸：玩家數（2/5/10）、注入節奏（5/20 ticks）、長度（1,200/12,000 ticks）。未變動軸：
  擾動時點（600）與擾動僅在核心 30 段的前 10 段上施加、砲塔（0）。
- 跨架構重驗已完成（`results/crossarch-x86_64.json`，2026-09-12）：41 段 arm64 錄音由
  seed 決定性重建（`--record --seed-id`）、tar 後以 sha256 對帳搬運至 x86_64 機器，
  `crossarch-verify.sh` 全數通過。重建用 commit `9c48092` 的 runner（非首次錄製的
  `d23d66d`）；重建檔於 arm64 本機 `--verify` 抽驗通過後才搬運。

Raw runner stdout 未入 repo（可由上列指令決定性重生）；`regenerate.py` 的資料來源為 `results/*.json`。

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
- host: Apple M2, macOS（8 cores, 16 GB）, arm64；跨架構重驗首次於 AMD Ryzen 5 7600X / WSL2 Ubuntu / Swift 6.2.3（x86_64）執行，見 Results 末表；record format 2.4/2.5 由兩台機器各自錄製與重驗（arm64 / Apple Swift 6.4.2；x86_64 / `swift:6.2.4-noble` 容器），3.0/3.1 只在 x86_64 執行，見各 Re-measurement 節

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

| machine | arch | commit | tree | swift | build | recordings | verified vs recorded | run1 == run2 | tick mismatches | ticks | client events | actions |
|---|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| Apple M2, macOS 27.2 | arm64 | `0d213f2f` | not recorded | Apple Swift 6.4.2 | release | 41 | 41/41 | 41/41 | 0 | 70,800 | 20,760 | 0 |
| AMD Ryzen 5 7600X, Linux (WSL2, Docker swift:6.2.4-noble) | x86_64 | `6e5cb141` | not recorded | Swift 6.2.4 | release | 41 | 41/41 | 41/41 | 0 | 70,800 | 20,760 | 0 |

## Re-measurement at record format 3.0

| machine | arch | commit | tree | swift | build | recordings | verified vs recorded | run1 == run2 | tick mismatches | ticks | client events | actions |
|---|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| AMD Ryzen 5 7600X, Linux (WSL2, Docker swift:6.2.4-noble) | x86_64 | `986097b7` | clean | Swift 6.2.4 | release | 41 | 41/41 | 41/41 | 0 | 70,800 | 20,760 | 0 |


## Re-measurement at record format 3.1

| machine | arch | commit | tree | swift | build | recordings | verified vs recorded | run1 == run2 | tick mismatches | ticks | client events | actions |
|---|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| AMD Ryzen 5 7600X, Linux (WSL2, Docker swift:6.2.4-noble) | x86_64 | `022d8fdb` | clean | Swift 6.2.4 | release | 41 | 41/41 | 41/41 | 0 | 70,800 | 20,760 | 0 |

## Conclusion

41 段錄音共 **70,800 ticks**（核心 30×1,200 + 玩家數/注入節奏變體 9 段 + 兩段 12,000-tick 長程）
重播驗證 **0 hash mismatch**，且每段 run1 與 run2 完全一致。最新一次在 record format 3.1
（`022d8fdb`，x86_64，Swift 6.2.4）：41/41 verified vs recorded、41/41 run1 == run2、0 tick
mismatch。這是計數，不換算成 per-tick mismatch 機率的上界：同一段錄音內的 tick 不是獨立試驗。

擾動測試（Part B）是 2026-08-31 的紀錄（`d23d66d`，hash 為 broadcast view），2.4 起未重跑：
次解析度的浮點擾動（1e-7，量化前，加在 moveSpeed）10/10 被定點量化吸收（仍 0 mismatch），而移動中
玩家 x 座標的 ≥1 LSB 偏移 10/10 在注入當 tick（延遲 0）被逐 tick hash 比對暴露。亦即：(1)
**量化屏障**——低於量化步長的浮點雜訊寫不進定點狀態，決定性不依賴偵測來維持；(2) **稽核靈敏度**
——對移動中玩家座標的 ≥1 LSB 偏移，離線重播驗證的逐 tick hash 比對當拍暴露它。現在的 hash（2.4
起）涵蓋每個 `@Sync` 欄位，不含 `@Internal` 屬性。此驗證屬 audit-time（重播稽核／CI）
機制，非 runtime 監測。

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

Part B (perturbation) was not re-run at 2.4.

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

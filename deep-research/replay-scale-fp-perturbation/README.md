# Replay verification at scale + FP perturbation sensitivity

## Question

(A) 大規模重播驗證（數十段錄音、上萬 ticks）下，逐 tick state-hash 比對是否維持 0 mismatch？
(B) 在重播中注入浮點／定點擾動時，hash 驗證能否偵測、偵測延遲幾個 tick？

> 名詞：遊戲狀態使用定點數（整數，scale 1000）。**LSB = 定點表示的最小刻度（量化步長），
> 1 LSB = 整數 +1 = 0.001 世界座標——不是浮點的最小單位（ULP）**；狀態的任何改變至少 1 LSB。
> Float 只出現在量化前的中間計算。
> **浮點擾動** = 在量化前對 Float 輸入（移速）加極小偏移，模擬跨平台浮點捨入差異；
> **定點擾動** = 直接對量化後的整數座標加 N 個 LSB，模擬真正改變狀態的最小誤差。

## Environment

- date: 2026-08-31
- git_sha: `d23d66d`（`experiment/replay-scale-fp-perturbation` branch；含 `--record` 模式、擾動 hook、與確定性迭代修正）
- swift_version: Apple Swift 6.3.2, build_config: release
- host: Apple M2, macOS（8 cores, 16 GB）, arm64（錄製與重播同架構；跨架構證據見 2026-02 evidence）

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
## Conclusion

41 段錄音共 **70,800 ticks**（核心 30×1,200 + 玩家數/注入節奏變體 9 段 + 兩段 12,000-tick 長程）
重播驗證 **0 hash mismatch**，且每段 run1 與 run2 完全一致——對應 per-tick mismatch 機率的
95% rule-of-three 上界 ≈ 3/70,800 ≈ 4.2×10⁻⁵；次解析度的浮點擾動（1e-7，量化前）10/10 被定點量化吸收（仍 0 mismatch），
而 ≥1 LSB 的狀態擾動 10/10 在注入當 tick（延遲 0）被逐 tick hash 比對暴露。亦即：(1) **量化屏障**——
低於量化步長的浮點雜訊寫不進定點狀態，決定性不依賴偵測來維持；(2) **稽核靈敏度**——一旦狀態
真的偏移（最小 1 LSB），離線重播驗證的逐 tick hash 比對當拍、無盲區地暴露它。此驗證屬
audit-time（重播稽核／CI）機制，非 runtime 監測。

## Caveats

- **本實驗過程中發現並修正了一個真實的決定性 bug**：hero-defense tick handler 與最近目標選擇
  依賴 Dictionary 迭代順序，1,200-tick 規模下 28/30 段重播發散（短錄音從未觸發）。修正為
  sorted-key 迭代與 lowest-id tie-break（commit `d23d66d`）後才有上表結果。此發現本身即為
  規模化驗證的價值證據，詳見設計文件 Findings。
- **重播的 server event sequence 編號與錄製不同**（重播不推進共用序號計數器，已知缺口）：
  Runner 以內容級比對（tickId/type/payload/target）複核，純序號差異降為明示警告；core 修復
  為後續工作。本表所有 record 的事件內容比對皆通過。
- 錄製與重播同為 arm64/macOS；跨架構（arm64→x86_64）證據見
  `deep-research/emse-artifacts/evidence-2026-02-06-*`。
- 擾動作用於當 tick 所有移動中的玩家（非單一玩家）；latency 以「首個 mismatch tick − 600」計。
- 錄音檔（每段 ~1200 ticks）未入 repo：由 `--record --seed-id <N>` 可決定性重建。
- 已變動軸：玩家數（2/5/10）、注入節奏（5/20 ticks）、長度（1,200/12,000 ticks）。未變動軸：
  擾動時點（600）與擾動僅在核心 30 段的前 10 段上施加、砲塔（0）。
- 跨架構重驗：`crossarch-verify.sh` 於 x86_64 機器上對同一批 arm64 錄音執行（結果另行補入）。

Raw runner stdout 未入 repo（可由上列指令決定性重生）；`regenerate.py` 的資料來源為 `results/*.json`。

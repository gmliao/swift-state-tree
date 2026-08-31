# Replay verification at scale + FP perturbation sensitivity

## Question

(A) 大規模重播驗證（數十段錄音、上萬 ticks）下，逐 tick state-hash 比對是否維持 0 mismatch？
(B) 在重播中注入浮點／定點擾動時，hash 驗證能否偵測、偵測延遲幾個 tick？

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
| A | seed | 1–30 | 1,200 ticks、5 players、MoveTo every 20 ticks |
| B | 擾動 | float 1e-7 / fixed +1 LSB / fixed +1000 LSB | perturb tick = 600，seeds 1–10 |

## Results

### Part A — replay verification at scale (aggregate)

| recordings | total ticks | total actions | total client events | hash mismatches | verified vs recorded | run1 == run2 |
|---:|---:|---:|---:|---:|---:|---:|
| 30 | 36000 | 0 | 9000 | 0 | 30/30 | 30/30 |

### Part A — per recording

| seed | ticks | actions | client events | hash mismatches | verified |
|---:|---:|---:|---:|---:|---|
| 1 | 1200 | 0 | 300 | 0 | yes |
| 2 | 1200 | 0 | 300 | 0 | yes |
| 3 | 1200 | 0 | 300 | 0 | yes |
| 4 | 1200 | 0 | 300 | 0 | yes |
| 5 | 1200 | 0 | 300 | 0 | yes |
| 6 | 1200 | 0 | 300 | 0 | yes |
| 7 | 1200 | 0 | 300 | 0 | yes |
| 8 | 1200 | 0 | 300 | 0 | yes |
| 9 | 1200 | 0 | 300 | 0 | yes |
| 10 | 1200 | 0 | 300 | 0 | yes |
| 11 | 1200 | 0 | 300 | 0 | yes |
| 12 | 1200 | 0 | 300 | 0 | yes |
| 13 | 1200 | 0 | 300 | 0 | yes |
| 14 | 1200 | 0 | 300 | 0 | yes |
| 15 | 1200 | 0 | 300 | 0 | yes |
| 16 | 1200 | 0 | 300 | 0 | yes |
| 17 | 1200 | 0 | 300 | 0 | yes |
| 18 | 1200 | 0 | 300 | 0 | yes |
| 19 | 1200 | 0 | 300 | 0 | yes |
| 20 | 1200 | 0 | 300 | 0 | yes |
| 21 | 1200 | 0 | 300 | 0 | yes |
| 22 | 1200 | 0 | 300 | 0 | yes |
| 23 | 1200 | 0 | 300 | 0 | yes |
| 24 | 1200 | 0 | 300 | 0 | yes |
| 25 | 1200 | 0 | 300 | 0 | yes |
| 26 | 1200 | 0 | 300 | 0 | yes |
| 27 | 1200 | 0 | 300 | 0 | yes |
| 28 | 1200 | 0 | 300 | 0 | yes |
| 29 | 1200 | 0 | 300 | 0 | yes |
| 30 | 1200 | 0 | 300 | 0 | yes |

### Part B — perturbation sensitivity (perturb at tick 600, 10 recordings each)

| mode | eps | detected | detection latency (ticks) |
|---|---|---:|---|
| float +1e-7 (sub-LSB, pre-quantization) | 1e-07 | 0/10 | — |
| fixed +1 LSB (0.001 world units) | 1 | 10/10 | min 0 / max 0 |
| fixed +1000 LSB (1.0 world unit) | 1000 | 10/10 | min 0 / max 0 |

## Conclusion

30 段 × 1,200 ticks（36,000 ticks、9,000 個 client events）重播驗證 **0 hash mismatch**，且每段
run1 與 run2 完全一致；次解析度的浮點擾動（1e-7，量化前）10/10 被定點量化吸收（仍 0 mismatch），
而 ≥1 LSB 的狀態擾動 10/10 在注入當 tick（延遲 0）被逐 tick hash 比對偵測。亦即：驗證機制對
「會改變定點狀態的最小擾動」即時敏感，對「低於定點解析度的浮點雜訊」則因量化而免疫。

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
- 未變動軸：ticks/段（1,200）、玩家數（5）、注入節奏（20 ticks）、擾動時點（600）、砲塔（0）。

Raw runner stdout 未入 repo（可由上列指令決定性重生）；`regenerate.py` 的資料來源為 `results/*.json`。

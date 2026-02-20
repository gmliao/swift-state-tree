# Same-Land Reevaluation 驗證報告

[English](2026-02-20-low-risk-same-land-reevaluation-verification.md) | [中文版](2026-02-20-low-risk-same-land-reevaluation-verification.zh-TW.md)

## 範圍

針對低風險 same-land reevaluation 實作的驗證（計畫：`2026-02-20-low-risk-same-land-reevaluation-plan.md`）。Replay 使用與 live 相同的 `LandDefinition`；active server path 中不再有獨立的 replay gameplay land。

## 驗證日期

- 2026-02-20

## Step 1：Deterministic Correctness 測試

所有必要測試 suite 皆通過：

| 測試 Suite | 結果 | 備註 |
|------------|------|------|
| `HeroDefenseReplayStateParityTests` | PASS | 10 tests（從 `Examples/GameDemo` 執行） |
| `ReevaluationReplayCompatibilityTests` | PASS | 12 tests |
| `ReevaluationFeatureRegistrationTests` | PASS | 4 tests |
| `NIOAdminRoutesReplayStartTests` | PASS | 9 tests |

指令：

```bash
cd Examples/GameDemo && swift test --filter HeroDefenseReplayStateParityTests
swift test --filter ReevaluationReplayCompatibilityTests
swift test --filter ReevaluationFeatureRegistrationTests
swift test --filter NIOAdminRoutesReplayStartTests
```

## Step 2：Replay E2E 穩定性

- `./Tools/CLI/test-e2e-game.sh`：**PASS**（所有 encoding：json、jsonOpcode、messagepack）
- 每個 encoding 執行：Hero Defense scenario suite + reevaluation record+verify（僅 messagepack）+ **replay stream E2E**
- Replay E2E 在三個 transport encoding 下皆通過

註：單一 server 實例連續執行 5 次 `test:e2e:game:replay` 可能遇到 server 生命週期問題（WebSocket 1006、replay session 結束時 process trap）。完整的 `test-e2e-game.sh` 會為每個 encoding 啟動/停止 server，可穩定通過。

## Step 3：效能證據

- **Baseline**：`86eb25c`（tag：`replay-low-risk-baseline-v2`）
- **目前路徑**：Same-land reevaluation（無 replay-only land）
- **mismatch 數**：0（deterministic correctness 測試通過）
- **Replay timeout**：0（在 `test-e2e-game.sh` 執行中）

本驗證未執行正式的 baseline vs 新路徑效能比較（CPU、RSS、完成時間變異）。計畫中的目標：

- CPU：replay path 至少改善 15%
- 記憶體：replay peak RSS 至少改善 10%
- 延遲：10 次 replay 的 (p95−p50) 至少改善 20%

可於 dedicated 效能 run 中量測：checkout baseline、以 instrumentation 執行 replay E2E 10×，再於目前 HEAD 重複執行。

## Step 4：最終 Gate

```bash
swift test
cd Tools/CLI && npm run test:e2e:game:replay
```

- `swift test`：**PASS**（728 tests in 39 suites）
- `test:e2e:game:replay`：需先啟動 GameServer（`ENABLE_REEVALUATION=true`）。完整 CI 含 replay 請使用 `./Tools/CLI/test-e2e-game.sh`。

## 摘要

| 檢查項目 | 狀態 |
|----------|------|
| Deterministic correctness | PASS |
| Replay E2E（所有 encoding） | PASS |
| 完整 `swift test` | PASS |
| Same-land 註冊 | 已驗證（GameServer path 無 HeroDefenseReplay） |
| Schema `hero-defense-replay` alias | 透過 `replayLandTypes` 約定 |

## 相關

- 計畫：`docs/plans/2026-02-20-low-risk-same-land-reevaluation-plan.md`
- Schema 約定：`SchemaGenCLI.generateSchema(..., replayLandTypes: ["hero-defense"])`

[English](2026-02-19-replay-generic-baseline-checklist.md) | [中文版](2026-02-19-replay-generic-baseline-checklist.zh-TW.md)

# Replay Generic 基準對比清單

## 基準版本鎖定

- Tag：`replay-baseline-v1`
- Branch：`codex/replay-baseline-v1`
- Commit：`efa46072016100de6dc0d2d0916149bf844d85eb`
- 基準日期：2026-02-19

## 目的

後續 generic replay 架構調整時，固定與此可播放版本比對，避免功能漂移。

## 必要比對面向

1. 決定論正確性
- Replay tick hash parity（基準情境應為 `mismatches=0`）。
- 總 tick 數不可退化。

2. 狀態一致性
- `players`、`turrets`、`monsters`、`base`、`score` 的演進需符合預期。
- 抽樣驗證位置欄位（`players[*].position`、`turrets[*].position`、`base.position`）。

3. 伺服器事件完整性
- Replay 串流需有戰鬥視覺事件（`PlayerShoot`、`TurretFire`）。
- Replay 串流需觀察到 monster 移除/擊殺狀態轉換。
- strict 模式下不依賴 replay-only fallback event 合成。

4. 使用者體驗
- Replay 啟動/載入失敗需顯示於 UI（非僅 console）。
- Replay 相機可用性維持（起始對準 base、replay 點擊移動）。
- 從 monitor UI 可一鍵啟動 replay。

5. API 簡化目標（未來）
- 伺服器端：reevaluation 以單一 feature 宣告啟用。
- 客戶端：replay mode 切換由 SDK 層 API 提供，不再靠頁面手工拼接流程。

## 基準驗證命令

1. CLI replay E2E
- `cd Tools/CLI && npm run test:e2e:game:replay`

2. Swift 單元測試
- `swift test`

3. Web replay 證據（Playwright CLI）
- `cd Examples/GameDemo/WebClient && npx playwright test`

## 每次比對要保存的證據

- 受測 commit hash。
- E2E 摘要（pass/fail 與 replay 關鍵斷言）。
- Playwright proof 摘要（`total`、`correct`、`mismatches`）。
- 若失敗：第一個失敗 tick ID 與事件/狀態差異片段。

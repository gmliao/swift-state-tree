[English](2026-02-01-uws-loadtest-design.md) | [中文版](2026-02-01-uws-loadtest-design.zh-TW.md)

# Hero Defense 的 UWS 壓測工具（設計）

## 目標
- 建立以 `ws` 為基礎的新壓測工具，驗證 `hero-defense` 的**穩定性**與**效能**。
- 以真實客戶端連線流程（connect + join + 持續送事件）進行測試。
- 產出**全新的 JSON + HTML 報表格式**（不沿用既有 server-loadtest）。
- 同時收集**客戶端指標**（RTT、state update 節奏、吞吐、錯誤/斷線率）與**伺服器指標**（CPU/記憶體/Load）。

## 非目標
- 不沿用 `Tools/CLI` 的 scenario 格式或驗證流程。
- 第一版不支援 churn（斷線/重連）。
- 第一版只支援 `messagepack` 編碼。

## 目錄與結構
根目錄：`Examples/GameDemo/uws-loadtest/`
建議結構：
```
uws-loadtest/
  package.json
  src/
    cli.ts
    orchestrator.ts
    worker.ts
    scenario.ts
    metrics.ts
    report/
      render-html.ts
  scripts/
    run-uws-loadtest.sh
  scenarios/
    hero-defense/
      default.json
  results/
    uws-loadtest-<timestamp>.json
    uws-loadtest-<timestamp>.html
  monitoring/
    collect-system-metrics.sh
```

## Scenario 格式
- Scenario 為 JSON（版本控管），放在 `scenarios/hero-defense/`。
- `phases` 固定三段：`preflight`、`steady`、`postflight`。
- 每段可設定：`durationSeconds`、`rooms`、`playersPerRoom`、`actionsPerSecond`、`verify`（是否驗證）、`joinPayloadTemplate`、`thresholds`。
- 預設值：若未指定 `rooms` → `500`；其他未填欄位由程式提供預設。
- actions/events 以名稱＋payload 模板描述（支援 `{playerId}`、`{randInt:1:9999}` 等佔位符）。
- 門檻（錯誤率/斷線率/P95/P99）由 scenario 定義。

## 執行模型
- Orchestrator 讀 scenario，計算總連線數（`rooms * playersPerRoom`）。
- 多進程 worker 依**連線數平均分配**。
- 每個 worker：
  - 建立 `ws` socket 並 join（使用模板填值）。
  - 依 `actionsPerSecond` 送事件。
  - `steady` 段不做逐筆斷言，只記錄統計與健康檢查。
  - `preflight`/`postflight` 可啟用驗證。

## 指標與門檻
客戶端指標：
- **RTT**：request → response 的時間（P50/P95/P99）。
- **State update 節奏**：更新間隔分佈（P50/P95/P99）。
- 吞吐、錯誤率、斷線率。

伺服器指標：
- CPU、記憶體、Load/IO（macOS/Linux），由腳本取樣並合併到報表。

門檻處理：
- 未達門檻時，在報表標記 fail，但**不影響 exit code**。

## 報表輸出
- 使用全新 JSON schema。
- HTML 圖表呈現：
  - RTT 分位數曲線
  - State update 節奏
  - 錯誤/斷線率
  - 伺服器 CPU/記憶體曲線
- 輸出到 `results/uws-loadtest-<timestamp>.{json,html}`。

## 執行預設
- 編碼：僅 `messagepack`。
- 伺服器：自動啟動 `GameServer`、等待可用、超時強制關閉。
- URL 可由 CLI 參數覆寫；預設 `ws://localhost:8080/game/hero-defense`。

## 風險與對策
- **驗證成本**：只在 `preflight`/`postflight` 開啟完整驗證。
- **缺少 churn**：明確標示為後續工作。
- **伺服器卡住**：腳本等待並硬性終止，避免測試卡死。

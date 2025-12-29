# 8 核心 CPU 承載能力估算（以 30 人房間為例）

本文件的目標是把「TransportAdapter.syncNow() 的 benchmark 數據」轉成可用的容量估算方式，並把不同情境（dirty ratio / 公開狀態是否每 tick 都在變）分開說清楚。

## 測試環境與測到的是什麼

- **硬體**：MacBook Air M2（Apple Silicon）
- **CPU**：8 核心（4P + 4E）
- **編譯模式**：Release
- **測量內容**：`TransportAdapter.syncNow()` 的 CPU 時間（含 snapshot/diff/MessagePack 或 JSON encode + mock transport send）
- **不包含**：真實網路（TCP/TLS/WebSocket）、封包排隊、Client 端處理、跨機器延遲

> 結論用法：把這裡的結果當成「server 端同步邏輯的 CPU 基準」，真實環境請用你自己的 state/tick/action 重新跑一次 benchmark 再估算。

## 這次更新的 benchmark 檔案（MessagePack vs JSON，2025-12-28）

- **MessagePack（新預設）**
  - `docs/performance/transport-sync-dirty-on-messagepack-20251228-223728.txt`
  - `docs/performance/transport-sync-dirty-off-messagepack-20251228-223728.txt`
  - `docs/performance/transport-sync-players-dirty-on-messagepack-20251228-223728.txt`
  - `docs/performance/transport-sync-players-dirty-off-messagepack-20251228-223728.txt`
- **JSON（對照組）**
  - `docs/performance/transport-sync-dirty-on-json-20251228-223728.txt`
  - `docs/performance/transport-sync-dirty-off-json-20251228-223728.txt`
  - `docs/performance/transport-sync-players-dirty-on-json-20251228-223728.txt`
  - `docs/performance/transport-sync-players-dirty-off-json-20251228-223728.txt`

執行方式（Release）：

```bash
swift run -c release SwiftStateTreeBenchmarks transport-sync --dirty-on --no-wait --csv --encoding=messagepack
swift run -c release SwiftStateTreeBenchmarks transport-sync --dirty-off --no-wait --csv --encoding=messagepack
swift run -c release SwiftStateTreeBenchmarks transport-sync-players --dirty-on --no-wait --csv --encoding=messagepack
swift run -c release SwiftStateTreeBenchmarks transport-sync-players --dirty-off --no-wait --csv --encoding=messagepack

swift run -c release SwiftStateTreeBenchmarks transport-sync --dirty-on --no-wait --csv --encoding=json
swift run -c release SwiftStateTreeBenchmarks transport-sync --dirty-off --no-wait --csv --encoding=json
swift run -c release SwiftStateTreeBenchmarks transport-sync-players --dirty-on --no-wait --csv --encoding=json
swift run -c release SwiftStateTreeBenchmarks transport-sync-players --dirty-off --no-wait --csv --encoding=json
```

## Benchmark 模型（你在估算時要知道的假設）

### State 結構（精簡）

`TransportAdapterSyncBenchmarkRunner` 目前用的狀態是：

- broadcast：`round`、`players: [PlayerID: BenchmarkPlayerState]`
- per-player：`hands: [PlayerID: BenchmarkHandState]`

### 兩種情境差異

- `transport-sync`：每 tick **一定改 `round`**，另外改一部分玩家的 `hands`（依 dirty ratio），但 **通常不改 `players`**。
- `transport-sync-players`：在上述基礎上，另外每 tick **也會改 `players`（預設 ~100% 玩家）**，模擬「位置/HP/狀態等公開資訊常常更新」。

### dirty ratio 的意思

這裡的 Low/Medium/High 是「每 tick 會被挑中去改 per-player hands 的玩家比例（約略）」：

- Low：~5%
- Medium：~20%
- High：~80%

> 注意：目前 dirty tracking 是「欄位名」粒度，像 `hands` 只要任何玩家改到，實作上仍會對所有玩家做 per-player snapshot/diff（只是比對範圍縮小到 `hands` 欄位本身）。因此玩家數上升時仍會看到 O(players) 的成本。

## 最新數據（MessagePack，建議用 Medium State 估算）

下面列的是 **Medium State（Cards/Player: 10）**，取 **30 人房間** 與 **50 人房間** 的平均時間（100 iterations）。

### 情境 A：`transport-sync`（players 通常不變）

| Dirty Ratio | 30 人（dirty on） | 30 人（dirty off） | 50 人（dirty on） | 50 人（dirty off） |
| --- | ---: | ---: | ---: | ---: |
| Low ~5% | 1.0946ms | 1.3225ms | 1.4496ms | 1.6407ms |
| Medium ~20% | 1.9554ms | 4.5125ms | 3.7488ms | 8.3757ms |
| High ~80% | 5.8755ms | 9.6647ms | 7.3090ms | 13.8418ms |

### 情境 B：`transport-sync-players`（公開 players 也會變）

| Dirty Ratio | 30 人（dirty on） | 30 人（dirty off） | 50 人（dirty on） | 50 人（dirty off） |
| --- | ---: | ---: | ---: | ---: |
| Low hands ~5% | 1.5443ms | 1.3980ms | 1.5685ms | 1.8822ms |
| Medium hands ~20% | 5.5412ms | 8.5613ms | 9.9671ms | 13.7333ms |
| High hands ~80% | 17.0534ms | 15.3976ms | 20.5973ms | 23.7288ms |

> 解讀：當 `players` 也變動時（情境 B），sync 成本會明顯上升，而且 dirty tracking 的優勢通常會縮小（因為最大的 broadcast payload 變成「每 tick 都是 dirty」）。

## 大小趨勢（MessagePack vs JSON）

先前含 size 統計的測試顯示：MessagePack 多數情境 **比 JSON 小約 20%～40%**，多數落在 **約 30%** 的縮減幅度；在 `transport-sync-players` 的低 dirty 情境，差異會縮小，少數情況可能接近或略大。

## 優化前後差異（JSON → MessagePack）

以下以 **Medium State（Cards/Player: 10）** 為基準，對比 **JSON vs MessagePack** 的差異。Δ% 為 `(MessagePack - JSON) / JSON`，負值代表變快。

### 情境 A：`transport-sync`（players 通常不變）

| Dirty Ratio | 30人 dirty on | 30人 dirty off | 50人 dirty on | 50人 dirty off |
| --- | ---: | ---: | ---: | ---: |
| Low | 1.1050 → 1.0946 (-0.94%) | 1.3573 → 1.3225 (-2.56%) | 1.2637 → 1.4496 (+14.71%) | 2.0341 → 1.6407 (-19.34%) |
| Medium | 2.5109 → 1.9554 (-22.12%) | 7.3465 → 4.5125 (-38.58%) | 3.2704 → 3.7488 (+14.63%) | 8.0150 → 8.3757 (+4.50%) |
| High | 8.3664 → 5.8755 (-29.77%) | 12.8807 → 9.6647 (-24.97%) | 10.1426 → 7.3090 (-27.94%) | 20.2405 → 13.8418 (-31.61%) |

### 情境 B：`transport-sync-players`（公開 players 也會變）

| Dirty Ratio | 30人 dirty on | 30人 dirty off | 50人 dirty on | 50人 dirty off |
| --- | ---: | ---: | ---: | ---: |
| Low | 1.3822 → 1.5443 (+11.73%) | 1.9033 → 1.3980 (-26.55%) | 1.8207 → 1.5685 (-13.85%) | 2.3840 → 1.8822 (-21.05%) |
| Medium | 7.4528 → 5.5412 (-25.65%) | 14.0348 → 8.5613 (-39.00%) | 12.3062 → 9.9671 (-19.01%) | 19.0402 → 13.7333 (-27.87%) |
| High | 17.6248 → 17.0534 (-3.24%) | 21.7137 → 15.3976 (-29.09%) | 34.9247 → 20.5973 (-41.02%) | 30.9687 → 23.7288 (-23.38%) |

> 補充：在 `transport-sync-players` 且 dirty tracking 關閉時，MessagePack 並非全面更快；Medium hands 比例特別容易偏慢（此組 JSON 反而較快）。

## 與 2025-12-19 基準對比（注意測量方法差異）

以下以 **2025-12-19（JSON encode optimized）** 為舊基準，對比 **這次 MessagePack**。Δ% 為 `(新 - 舊) / 舊`，負值代表變快。  
**注意**：本次 benchmark 會註冊 mock connections 並計算 outgoing bytes，CPU 時間包含 per-recipient send 迴圈成本，因此與舊結果不是完全等價的量測；僅供趨勢參考。

### 情境 A：`transport-sync`（players 通常不變）

| Dirty Ratio | 30人 dirty on | 30人 dirty off | 50人 dirty on | 50人 dirty off |
| --- | ---: | ---: | ---: | ---: |
| Low | 0.9841 → 1.0946 (+11.23%) | 1.0549 → 1.3225 (+25.37%) | 1.1664 → 1.4496 (+24.28%) | 1.3714 → 1.6407 (+19.64%) |
| Medium | 1.7365 → 1.9554 (+12.61%) | 3.1756 → 4.5125 (+42.10%) | 2.5098 → 3.7488 (+49.37%) | 4.4463 → 8.3757 (+88.37%) |
| High | 5.3744 → 5.8755 (+9.32%) | 8.4023 → 9.6647 (+15.02%) | 7.7280 → 7.3090 (-5.42%) | 10.9950 → 13.8418 (+25.89%) |

### 情境 B：`transport-sync-players`（公開 players 也會變）

| Dirty Ratio | 30人 dirty on | 30人 dirty off | 50人 dirty on | 50人 dirty off |
| --- | ---: | ---: | ---: | ---: |
| Low | 0.9661 → 1.5443 (+59.85%) | 1.0158 → 1.3980 (+37.63%) | 1.2035 → 1.5685 (+30.33%) | 1.1955 → 1.8822 (+57.44%) |
| Medium | 4.3152 → 5.5412 (+28.41%) | 5.6022 → 8.5613 (+52.82%) | 6.4487 → 9.9671 (+54.56%) | 7.7446 → 13.7333 (+77.33%) |
| High | 11.6819 → 17.0534 (+45.98%) | 14.0109 → 15.3976 (+9.90%) | 15.9688 → 20.5973 (+28.98%) | 19.2631 → 23.7288 (+23.18%) |

## 容量估算方式（8 核心 / 80% 可用 CPU）

### 基本變數

- `syncMs`：benchmark 的 `syncNow()` 平均時間（毫秒）
- `tickHz`：每秒同步次數（例如 20Hz = 50ms/tick）
- `overheadFactor`：除 sync 以外的 server 開銷比例（遊戲邏輯、action/event、排程、logging、真實 I/O…）
  - 例如 `0.5` 代表其他開銷約等於 sync 的 50%
- `cpuBudgetMsPerSec`：CPU 每秒可用時間
  - 8 核心 × 1000ms × 0.8 ≈ **6400ms/秒**

估算公式：

```
roomCpuPerSec = syncMs * (1 + overheadFactor) * tickHz
rooms = cpuBudgetMsPerSec / roomCpuPerSec
```

### 用情境 B（公開 players 也會變）做 30 人房間示例

以 **Medium State / 30 人 / dirty on** 為例：

- Low hands ~5%：`syncMs = 1.5443`
- Medium hands ~20%：`syncMs = 5.5412`
- High hands ~80%：`syncMs = 17.0534`

假設 `overheadFactor = 0.5`：

- **20Hz（50ms/tick）**
  - Low：`rooms ≈ 6400 / (1.5443 * 1.5 * 20) ≈ 138`
  - Medium：`rooms ≈ 6400 / (5.5412 * 1.5 * 20) ≈ 38`
  - High：`rooms ≈ 6400 / (17.0534 * 1.5 * 20) ≈ 13`
- **10Hz（100ms/tick）**
  - Low：約 276
  - Medium：約 77
  - High：約 25

> 這個範圍差很大是正常的：同步成本主要由「每 tick 你到底改了多少東西」決定。

## 實務建議

1. **如果你的遊戲每 tick 都會刷新大多數玩家的公開狀態**（位置/速度/HP…），請以 `transport-sync-players-*.txt` 作為估算基準。
2. **Dirty tracking 是否要開**：在 Medium/High 變動的情境下，dirty on 通常更划算；但在「接近全量變動」且 state 結構特殊時，dirty off 可能接近甚至略快（請用你的 state 實測）。
3. **下一個瓶頸通常是 O(players) per-player diff**：目前只知道「hands 欄位 dirty」，不知道「哪些 PlayerID 的 hands 改了」，所以玩家數大時仍會線性成長；要再往下壓，需要 key-level dirty（例如 `ReactiveDictionary.dirtyKeys`）或回傳受影響 PlayerIDs。

# 8 核心 CPU 承載能力估算（以 30 人房間為例）

本文件的目標是把「TransportAdapter.syncNow() 的 benchmark 數據」轉成可用的容量估算方式，並把不同情境（dirty ratio / 公開狀態是否每 tick 都在變）分開說清楚。

## 測試環境與測到的是什麼

- **硬體**：MacBook Air M2（Apple Silicon）
- **CPU**：8 核心（4P + 4E）
- **編譯模式**：Release
- **測量內容**：`TransportAdapter.syncNow()` 的 CPU 時間（含 snapshot/diff/JSON encode + mock transport send）
- **不包含**：真實網路（TCP/TLS/WebSocket）、封包排隊、Client 端處理、跨機器延遲

> 結論用法：把這裡的結果當成「server 端同步邏輯的 CPU 基準」，真實環境請用你自己的 state/tick/action 重新跑一次 benchmark 再估算。

## 這次更新的 benchmark 檔案

- **原始情境（players 通常不變）**
  - dirty on：`docs/performance/transport-sync-dirty-on.txt`
  - dirty off：`docs/performance/transport-sync-dirty-off.txt`
- **更貼近實務（公開 players 也會每 tick 變動）**
  - dirty on：`docs/performance/transport-sync-players-dirty-on.txt`
  - dirty off：`docs/performance/transport-sync-players-dirty-off.txt`

執行方式（Release）：

```bash
bash Tools/CLI/run-transport-sync-benchmarks.sh
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

## 最新數據（建議用 Medium State 估算）

下面列的是 **Medium State（Cards/Player: 10）**，取 **30 人房間** 與 **50 人房間** 的平均時間（100 iterations）。

### 情境 A：`transport-sync`（players 通常不變）

| Dirty Ratio | 30 人（dirty on） | 30 人（dirty off） | 50 人（dirty on） | 50 人（dirty off） |
| --- | ---: | ---: | ---: | ---: |
| Low ~5% | 1.0236ms | 1.2403ms | 1.3125ms | 1.5122ms |
| Medium ~20% | 2.6569ms | 4.3845ms | 3.6410ms | 6.1370ms |
| High ~80% | 7.8179ms | 11.2919ms | 11.0818ms | 15.1113ms |

### 情境 B：`transport-sync-players`（公開 players 也會變）

| Dirty Ratio | 30 人（dirty on） | 30 人（dirty off） | 50 人（dirty on） | 50 人（dirty off） |
| --- | ---: | ---: | ---: | ---: |
| Low hands ~5% | 1.1023ms | 1.2832ms | 1.5308ms | 1.7293ms |
| Medium hands ~20% | 6.8705ms | 8.1062ms | 9.7098ms | 14.3067ms |
| High hands ~80% | 20.5187ms | 21.1264ms | 24.1068ms | 29.2436ms |

> 解讀：當 `players` 也變動時（情境 B），sync 成本會明顯上升，而且 dirty tracking 的優勢通常會縮小（因為最大的 broadcast payload 變成「每 tick 都是 dirty」）。

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

- Low hands ~5%：`syncMs = 1.1023`
- Medium hands ~20%：`syncMs = 6.8705`
- High hands ~80%：`syncMs = 20.5187`

假設 `overheadFactor = 0.5`：

- **20Hz（50ms/tick）**
  - Low：`rooms ≈ 6400 / (1.1023 * 1.5 * 20) ≈ 193`
  - Medium：`rooms ≈ 6400 / (6.8705 * 1.5 * 20) ≈ 31`
  - High：`rooms ≈ 6400 / (20.5187 * 1.5 * 20) ≈ 10`
- **10Hz（100ms/tick）**
  - Low：約 386
  - Medium：約 62
  - High：約 21

> 這個範圍差很大是正常的：同步成本主要由「每 tick 你到底改了多少東西」決定。

## 實務建議

1. **如果你的遊戲每 tick 都會刷新大多數玩家的公開狀態**（位置/速度/HP…），請以 `transport-sync-players-*.txt` 作為估算基準。
2. **Dirty tracking 是否要開**：在 Medium/High 變動的情境下，dirty on 通常更划算；但在「接近全量變動」且 state 結構特殊時，dirty off 可能接近甚至略快（請用你的 state 實測）。
3. **下一個瓶頸通常是 O(players) per-player diff**：目前只知道「hands 欄位 dirty」，不知道「哪些 PlayerID 的 hands 改了」，所以玩家數大時仍會線性成長；要再往下壓，需要 key-level dirty（例如 `ReactiveDictionary.dirtyKeys`）或回傳受影響 PlayerIDs。


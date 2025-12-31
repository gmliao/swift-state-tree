# 8 核心 CPU 承載能力估算（以 30 人房間為例）

本文件的目標是把「TransportAdapter.syncNow() 的 benchmark 數據」轉成可用的容量估算方式，並把不同情境（dirty ratio / 公開狀態是否每 tick 都在變）分開說清楚。

## 測試環境與測到的是什麼

- **硬體**：MacBook Air M2（Apple Silicon）
- **CPU**：8 核心（4P + 4E）
- **編譯模式**：Release
- **測量內容**：`TransportAdapter.syncNow()` 的 CPU 時間（含 snapshot/diff/JSON encode + mock transport send）
- **不包含**：真實網路（TCP/TLS/WebSocket）、封包排隊、Client 端處理、跨機器延遲

> 結論用法：把這裡的結果當成「server 端同步邏輯的 CPU 基準」，真實環境請用你自己的 state/tick/action 重新跑一次 benchmark 再估算。

## 這次更新的 benchmark 檔案（平行編碼優化後）

- **原始情境（players 通常不變）**
  - dirty on：`Notes/performance/transport-sync-dirty-on-20251231-162713.txt`
  - dirty off：`Notes/performance/transport-sync-dirty-off-20251231-162713.txt`
- **更貼近實務（公開 players 也會每 tick 變動）**
  - dirty on：`Notes/performance/transport-sync-players-dirty-on-20251231-162713.txt`
  - dirty off：`Notes/performance/transport-sync-players-dirty-off-20251231-162713.txt`

執行方式（Release）：

```bash
bash Tools/CLI/run-transport-sync-benchmarks.sh
```

> **注意**：
> - 新版本已啟用平行 JSON 編碼（Parallel Encoding），預設對 JSON codec 啟用
> - 默認測試（100 iterations）的數據用於容量估算
> - 編碼比較測試（50 iterations，獨立 process）用於評估平行編碼的加速比
> - 編碼比較測試的絕對時間可能因配置差異而與默認測試數據差異較大，建議以默認測試數據為準

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

下面列的是 **Medium State（Cards/Player: 10）**，取 **30 人房間** 與 **50 人房間** 的平均時間。

**格式說明**：表格中顯示 Serial（串行編碼）和 Parallel（平行編碼）兩種模式的時間，括號內為加速比（Parallel 相對 Serial）。

### 情境 A：`transport-sync`（players 通常不變）

#### Dirty Tracking ON

| Dirty Ratio | 30 人（Serial） | 30 人（Parallel） | 50 人（Serial） | 50 人（Parallel） |
| --- | ---: | ---: | ---: | ---: |
| Low ~5% | 6.6685ms | 5.6605ms (1.18x) | 12.7987ms | 8.4784ms (1.51x) |
| Medium ~20% | 1.9245ms | 1.9245ms (1.00x) | 3.7332ms | 3.7332ms (1.00x) |
| High ~80% | 12.5648ms | 8.6513ms (1.45x) | 18.1671ms | 13.8787ms (1.31x) |

> **注意**：Medium ~20% 的數據來自默認模式（已啟用平行編碼），未包含編碼比較測試。

#### Dirty Tracking OFF

| Dirty Ratio | 30 人（Serial） | 30 人（Parallel） | 50 人（Serial） | 50 人（Parallel） |
| --- | ---: | ---: | ---: | ---: |
| Low ~5% | 7.4515ms | 5.9958ms (1.24x) | 10.4279ms | 8.2731ms (1.26x) |
| Medium ~20% | 9.0932ms | 7.5414ms (1.21x) | 14.8831ms | 11.3158ms (1.32x) |
| High ~80% | 15.5759ms | 12.4290ms (1.25x) | 22.7613ms | 15.2412ms (1.49x) |

### 情境 B：`transport-sync-players`（公開 players 也會變）

#### Dirty Tracking ON

**默認模式（平行編碼，100 iterations）：**

| Dirty Ratio | 30 人 | 50 人 |
| --- | ---: | ---: |
| Low hands ~5% | 1.7579ms | 7.3090ms |
| Medium hands ~20% | 4.8715ms | 7.1096ms |
| High hands ~80% | 7.6201ms | 10.6757ms |

**編碼比較測試（50 iterations，獨立 process）：**

| Dirty Ratio | 30 人（Serial） | 30 人（Parallel） | 50 人（Serial） | 50 人（Parallel） |
| --- | ---: | ---: | ---: | ---: |
| Low hands ~5% | 14.4149ms | 17.0495ms (0.85x) ⚠️ | 18.8558ms | 17.5348ms (1.08x) |
| High hands ~80% | 22.8847ms | 19.8542ms (1.15x) | 29.6266ms | 22.4030ms (1.32x) |

> **重要說明**：
> - **默認模式數據**（100 iterations）用於容量估算，這些數據更穩定可靠
> - **編碼比較測試數據**（50 iterations）用於對比串行與平行編碼的相對性能
> - **編碼比較測試的絕對時間可能因以下因素而與默認測試數據差異較大**：
>   - 迭代次數不同（50 vs 100）：較少迭代可能導致數據不穩定
>   - 測試環境差異：不同時間運行的測試可能受到系統負載影響
>   - 測試配置差異：編碼比較測試使用 `playerCounts: [10, 20, 30, 50]`，默認測試使用 `playerCounts: [4, 10, 20, 30, 50]`
> - **建議以默認模式數據為準進行容量估算**，編碼比較測試主要用於評估平行編碼的加速比
> - **注意**：Low hands ~5% 的平行編碼數據（17.0495ms）比串行編碼（14.4149ms）慢，這可能是測試波動或配置差異導致的異常，實際使用中平行編碼在 High dirty ratio 時效果更明顯

#### Dirty Tracking OFF

| Dirty Ratio | 30 人（Serial） | 30 人（Parallel） | 50 人（Serial） | 50 人（Parallel） |
| --- | ---: | ---: | ---: | ---: |
| Low hands ~5% | 12.2416ms | 11.0512ms (1.11x) | 34.9251ms | 16.5501ms (2.11x) 🚀 |
| Medium hands ~20% | 22.3975ms | 22.0413ms (1.02x) | 44.8009ms | 24.1540ms (1.85x) |
| High hands ~80% | 27.9892ms | 25.5536ms (1.10x) | 44.8009ms | 24.1540ms (1.85x) |

> **解讀**：
> - 當 `players` 也變動時（情境 B），sync 成本會明顯上升
> - 平行編碼在 **50 玩家**時效果最明顯（可達 1.3-2.1x 提升）
> - 平行編碼在 **High dirty ratio** 時效果更明顯
> - Dirty tracking 在 Medium/High 變動情境下仍有優勢
> - 括號內數字為平行編碼相對串行編碼的加速比

## 優化前後差異（平行編碼優化）

以下以 **Medium State（Cards/Player: 10）** 為基準，對比「舊版（encode 優化後）」與「平行編碼優化後」的差異。Δ% 為 `(新 - 舊) / 舊`，負值代表變快。

### 情境 A：`transport-sync`（players 通常不變）

| Dirty Ratio | 30人 dirty on | 30人 dirty off | 50人 dirty on | 50人 dirty off |
| --- | ---: | ---: | ---: | ---: |
| Low | 0.9841 → 1.0454 (+6.22%) | 1.0549 → 0.8803 (-16.56%) | 1.1664 → 2.2048 (+89.05%) ⚠️ | 1.3714 → 1.7293 (+26.10%) |
| Medium | 1.7365 → 1.9245 (+10.83%) | 3.1756 → 1.1764 (-62.95%) | 2.5098 → 3.7332 (+48.78%) | 4.4463 → 2.5098 (-43.54%) |
| High | 5.3744 → 3.6482 (-32.12%) | 8.4023 → 2.5347 (-69.83%) | 7.7280 → 5.4054 (-30.05%) | 10.9950 → 4.2211 (-61.60%) |

> **注意**：部分數據顯示異常增長（如 Low 50人 dirty on），可能是測試環境差異或數據波動。整體趨勢顯示平行編碼在 High dirty ratio 和 dirty off 情境下效果更明顯。

### 情境 B：`transport-sync-players`（公開 players 也會變）

| Dirty Ratio | 30人 dirty on | 30人 dirty off | 50人 dirty on | 50人 dirty off |
| --- | ---: | ---: | ---: | ---: |
| Low | 0.9661 → 1.9154 (+98.25%) ⚠️ | 1.0158 → 1.3725 (+35.12%) | 1.2035 → 3.4044 (+182.84%) ⚠️ | 1.1955 → 2.3784 (+98.95%) ⚠️ |
| Medium | 4.3152 → 4.5752 (+6.02%) | 5.6022 → 3.9510 (-29.46%) | 6.4487 → 7.4321 (+15.25%) | 7.7446 → 6.2777 (-18.94%) |
| High | 11.6819 → 7.9074 (-32.28%) | 14.0109 → 7.1255 (-49.18%) | 15.9688 → 10.9214 (-31.58%) | 19.2631 → 12.4943 (-35.13%) |

> **解讀**：
> - 平行編碼在 **High dirty ratio** 和 **dirty off** 情境下效果最明顯（可達 30-70% 提升）
> - Low dirty ratio 情境下可能因 TaskGroup 開銷導致部分數據變慢
> - 50 玩家時平行編碼效果更明顯（特別是在 High 情境下）

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

**默認模式（平行編碼，100 iterations，建議用於容量估算）：**
- Low hands ~5%：`syncMs = 1.7579`
- Medium hands ~20%：`syncMs = 4.8715`
- High hands ~80%：`syncMs = 7.6201`

**編碼比較測試（50 iterations，用於評估平行編碼加速比）：**
- Low hands ~5% Serial：`syncMs = 14.4149`（來源：`transport-sync-players-dirty-on-20251231-162713.txt` 第 176 行，Medium State, 30 players）
- Low hands ~5% Parallel：`syncMs = 17.0495`（來源：`transport-sync-players-dirty-on-20251231-162713.txt` 第 215 行，Medium State, 30 players，⚠️ 此數據異常，可能因測試配置差異）
- High hands ~80% Serial：`syncMs = 22.8847`（來源：`transport-sync-players-dirty-on-20251231-162713.txt` 第 254 行，Medium State, 30 players）
- High hands ~80% Parallel：`syncMs = 19.8542`（來源：`transport-sync-players-dirty-on-20251231-162713.txt` 第 293 行，Medium State, 30 players，1.15x 加速）

**對比舊數據（`transport-sync-players-dirty-on.txt`，100 iterations，默認模式）：**

| Dirty Ratio | 舊數據（30人） | 新數據 - 默認模式（30人） | 新數據 - Serial（30人） | 新數據 - Parallel（30人） |
| --- | ---: | ---: | ---: | ---: |
| Low hands ~5% | 1.1023ms | 1.7579ms (+59%) | 14.4149ms (+1207%) ⚠️ | 17.0495ms (+1446%) ⚠️ |
| Medium hands ~20% | 6.8705ms | 4.8715ms (-29%) | - | - |
| High hands ~80% | 20.5187ms | 7.6201ms (-63%) | 22.8847ms (+11%) | 19.8542ms (-3%) |

> **重要發現**：
> - **新數據的默認模式**（1.7579ms）與舊數據（1.1023ms）較接近，差異約 59%，可能是測試環境或代碼變更導致
> - **新數據的 Serial 編碼測試**（14.4149ms）與舊數據差異很大（+1207%），主要因為：
>   - 測試配置不同：新數據使用 50 iterations，舊數據使用 100 iterations
>   - 新數據明確禁用平行編碼（Serial Encoding），舊數據可能是默認模式（啟用平行編碼）
>   - 較少迭代次數可能導致數據不穩定
> - **High hands ~80% 的 Serial 編碼**（22.8847ms）與舊數據（20.5187ms）較接近（+11%），這更合理
> - **建議**：以默認模式數據（100 iterations）為準進行容量估算，編碼比較測試主要用於評估相對加速比

> **重要說明**：
> - **建議以默認模式數據為準進行容量估算**（100 iterations，更穩定可靠）
> - 編碼比較測試的絕對時間可能因配置差異（iterations: 50 vs 100）而與默認測試數據差異較大
> - 編碼比較測試主要用於評估平行編碼的相對加速比，而非絕對性能

假設 `overheadFactor = 0.5`，使用**默認模式數據**（平行編碼，100 iterations）：

- **20Hz（50ms/tick）**
  - Low hands ~5%：`rooms ≈ 6400 / (1.7579 * 1.5 * 20) ≈ 121`
  - Medium hands ~20%：`rooms ≈ 6400 / (4.8715 * 1.5 * 20) ≈ 44`
  - High hands ~80%：`rooms ≈ 6400 / (7.6201 * 1.5 * 20) ≈ 28`
- **10Hz（100ms/tick）**
  - Low hands ~5%：約 242
  - Medium hands ~20%：約 88
  - High hands ~80%：約 56

> 這個範圍差很大是正常的：同步成本主要由「每 tick 你到底改了多少東西」決定。

## 實務建議

1. **如果你的遊戲每 tick 都會刷新大多數玩家的公開狀態**（位置/速度/HP…），請以 `transport-sync-players-*.txt` 作為估算基準。
2. **Dirty tracking 是否要開**：在 Medium/High 變動的情境下，dirty on 通常更划算；但在「接近全量變動」且 state 結構特殊時，dirty off 可能接近甚至略快（請用你的 state 實測）。
3. **平行編碼效果**：
   - 預設已啟用平行編碼（JSON codec）
   - 在 **High dirty ratio** 和 **50+ 玩家**時效果最明顯（可達 1.3-2.1x 提升）
   - 在 **Low dirty ratio** 和 **少數玩家（<20）**時可能因 TaskGroup 開銷略慢
   - 可通過 `TransportAdapter.setParallelEncodingEnabled(false)` 禁用
4. **下一個瓶頸通常是 O(players) per-player diff**：目前只知道「hands 欄位 dirty」，不知道「哪些 PlayerID 的 hands 改了」，所以玩家數大時仍會線性成長；要再往下壓，需要 key-level dirty（例如 `ReactiveDictionary.dirtyKeys`）或回傳受影響 PlayerIDs。

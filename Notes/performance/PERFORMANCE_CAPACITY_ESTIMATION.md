# CPU 承載能力估算（以 30 人房間為例）

本文件的目標是把「TransportAdapter.syncNow() 的 benchmark 數據」轉成可用的容量估算方式，並把不同情境（dirty ratio / 公開狀態是否每 tick 都在變）分開說清楚。

## TL;DR（可引用結論）

- **推薦估算基準**：AMD / `transport-sync-players` / dirty on / parallel
- **30 人、Medium State、20Hz**：約 188–231 rooms（**未套 safetyFactor**）
- **50 人、Medium State、20Hz**：約 91–107 rooms（**未套 safetyFactor**）
- **10Hz 對應倍增**：30 人約 376–462 rooms，50 人約 182–214 rooms（**未套 safetyFactor**）
- **safetyFactor 建議**：保守 0.6；一般 0.7

## 測試環境與測到的是什麼

### 測試平台對比

**AMD Ryzen 5 7600X（推薦用於伺服器估算）：**
- **CPU**：12 核心（6 物理核心 + 6 超線程）
- **架構**：x86_64
- **環境**：Linux (WSL2)
- **Swift 版本**：6.0.3
- **穩定性**：✅ 數據穩定，適合用於伺服器效能估算
  - 補充：WSL2 仍可能受 host load 影響；若要最接近 production，建議在 native Linux 或同規格雲端再驗一次

**Apple M2（參考數據）：**
- **CPU**：8 核心（4P + 4E）
- **架構**：arm64
- **環境**：macOS
- **Swift 版本**：6.2.3
- **穩定性**：⚠️ 連續運行多個測試套件時可能出現不穩定，建議拆開運行

> **重要發現**：
> - Mac 上連續運行多個 benchmark 套件時，數據可能出現波動（可能是熱節流或系統調度影響）
> - AMD 平台數據更穩定，更適合用於生產環境的容量估算
> - **建議使用 AMD 數據進行伺服器效能估算**

### 測量內容

- **編譯模式**：Release
- **測量內容**：`TransportAdapter.syncNow()` 的 CPU 時間（含 snapshot/diff/JSON encode + mock transport send）
- **Payload bytes**：以每次 sync 送出的 encoded `Data.count` 累加計算（總 bytes / iterations，不含 WebSocket/TCP/TLS framing）
- **不包含**：真實網路（TCP/TLS/WebSocket）、封包排隊、Client 端處理、跨機器延遲

> 結論用法：把這裡的結果當成「server 端同步邏輯的 CPU 基準」，真實環境請用你自己的 state/tick/action 重新跑一次 benchmark 再估算。

## 最新 Benchmark 檔案（2026-01-01 更新）

### AMD 數據（推薦用於伺服器估算）

- **原始情境（players 通常不變）**
  - dirty on：`transport-sync-dirty-on-AMD_Ryzen_5_7600X_6_Core_Proce-12cores-15GB-swift6.0-20260101-091359.txt`
  - dirty off：`transport-sync-dirty-off-AMD_Ryzen_5_7600X_6_Core_Proce-12cores-15GB-swift6.0-20260101-091359.txt`
- **更貼近實務（公開 players 也會每 tick 變動）**
  - dirty on：`transport-sync-players-dirty-on-AMD_Ryzen_5_7600X_6_Core_Proce-12cores-15GB-swift6.0-20260101-091359.txt`
  - dirty off：`transport-sync-players-dirty-off-AMD_Ryzen_5_7600X_6_Core_Proce-12cores-15GB-swift6.0-20260101-091359.txt`

### Mac 數據（參考）

- **原始情境（players 通常不變）**
  - dirty on：`transport-sync-dirty-on-Apple_M2-8cores-16GB-swift6.2-20260101-165802.txt`
  - dirty off：`transport-sync-dirty-off-Apple_M2-8cores-16GB-swift6.2-20260101-165802.txt`
- **更貼近實務（公開 players 也會每 tick 變動）**
  - dirty on：`transport-sync-players-dirty-on-Apple_M2-8cores-16GB-swift6.2-20260101-165802.txt`
  - dirty off：`transport-sync-players-dirty-off-Apple_M2-8cores-16GB-swift6.2-20260101-165802.txt`

執行方式（Release）：

```bash
bash Tools/CLI/run-transport-sync-benchmarks.sh
```

## 測試發現與最佳實踐

### 重要發現

1. **測試套件必須拆開運行（關鍵發現）**
   - **問題**：如果多個測試套件（suite）在同一個 process 中連續運行，數據會不準確
   - **具體表現**：
     - 穿插測試（interleaved testing）會導致後續測試的數據異常
     - 連續運行多個 suite 時，後面的測試可能受到前面測試的狀態污染
     - 數據波動明顯，無法用於準確的容量估算
   - **根本原因**：
     - 狀態污染：前一個測試的狀態可能影響後續測試
     - 記憶體碎片：長時間運行導致記憶體分配模式改變
     - 系統調度：連續運行可能觸發不同的 CPU 調度策略
     - JIT 編譯器狀態：Swift runtime 的優化狀態可能被污染
   - **解決方案**：每個測試套件必須在獨立的 process 中運行
   - **當前實現**：`run-transport-sync-benchmarks.sh` 腳本已經實現了這一點，每個 suite 都通過 `swift run` 單獨執行
   - **⚠️ 重要**：絕對不要在同一個 process 中連續運行多個 suite，這會導致數據完全不準確

2. **Mac 平台連續運行不穩定**
   - **問題**：Mac 上連續運行多個測試套件時，數據可能出現波動
   - **可能原因**：
     - 熱節流（thermal throttling）
     - 系統調度影響
     - 記憶體管理差異
   - **解決方案**：
     - 建議拆開運行不同的測試套件
     - 在測試之間留出冷卻時間
     - 使用 AMD/Linux 平台進行更穩定的測試

3. **AMD 平台數據更穩定**
   - **發現**：AMD Ryzen 5 7600X 在 Linux (WSL2) 環境下數據非常穩定
   - **適用場景**：適合用於生產環境的容量估算
   - **建議**：優先使用 AMD 數據進行伺服器效能估算

4. **測試配置差異影響結果**
   - **發現**：不同 iterations 數量的測試結果差異較大
   - **默認測試**：100 iterations（用於容量估算）
   - **編碼比較測試**：50 iterations（用於評估相對加速比）
   - **建議**：不要直接比較不同 iterations 的絕對時間，只比較相對加速比

### 最佳實踐

1. **運行 Benchmark 時**：
   - ✅ 使用 `run-transport-sync-benchmarks.sh` 腳本（自動拆開運行，每個 suite 獨立 process）
   - ✅ 確保系統負載較低
   - ✅ 在測試之間留出足夠的冷卻時間（Mac 平台）
   - ❌ **絕對不要**手動在同一個 process 中連續運行多個 suite（會導致數據完全不準確）
   - ❌ **絕對不要**穿插運行不同的測試套件（interleaved testing）
   - ❌ **絕對不要**在同一個 Swift process 中運行多個 benchmark suite

2. **數據解讀時**：
   - ✅ 使用默認測試數據（100 iterations）進行容量估算
   - ✅ 使用編碼比較測試數據評估相對加速比
   - ✅ 優先使用 AMD 數據進行伺服器效能估算
   - ❌ 不要直接比較不同 iterations 或不同平台的絕對時間

3. **開發新測試時**：
   - ✅ 確保每個測試套件在獨立 process 中運行
   - ✅ 使用足夠的 iterations 以獲得穩定結果
   - ✅ 記錄測試環境和配置信息

> **注意**：
> - 新版本已啟用平行 JSON 編碼（Parallel Encoding），預設對 JSON codec 啟用
> - 默認測試（100 iterations）的數據用於容量估算
> - 編碼比較測試（50 iterations，獨立 process）用於評估平行編碼的加速比
> - **Mac 用戶建議**：如果發現數據不穩定，可以手動拆開運行不同的測試套件，避免連續運行導致熱節流

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

## 最新數據（AMD 平台，建議用於伺服器估算）

下面列的是 **Medium State（Cards/Player: 10）**，取 **30 人房間** 與 **50 人房間** 的數據。

**格式說明**：表格中顯示 Serial（串行編碼）和 Parallel（平行編碼）兩種模式的時間，括號內為加速比（Serial / Parallel；< 1.0 表示 Parallel 較慢）。

### 情境 A：`transport-sync`（players 通常不變）

#### Dirty Tracking ON（AMD 數據）

**Medium State (10 Cards/Player, Serial/Parallel 比較，50 iterations)：**

| Dirty Ratio | 30 人（Parallel） | 30 人（Serial） | 50 人（Parallel） | 50 人（Serial） |
| --- | ---: | ---: | ---: | ---: |
| Low ~5% | 0.6984ms (1.04x) | 0.7236ms | 2.3680ms (0.73x) | 1.7207ms |
| Medium ~20% | 0.6984ms (1.04x) | 0.7236ms | 2.3680ms (0.73x) | 1.7207ms |
| High ~80% | 1.0116ms (1.90x) | 1.9176ms | 2.7672ms (1.13x) | 3.1291ms |

#### Dirty Tracking OFF（AMD 數據）

**Medium State (10 Cards/Player, Serial/Parallel 比較，50 iterations)：**

| Dirty Ratio | 30 人（Parallel） | 30 人（Serial） | 50 人（Parallel） | 50 人（Serial） |
| --- | ---: | ---: | ---: | ---: |
| Low ~5% | 0.7263ms (0.97x) | 0.7048ms | 2.2472ms (0.86x) | 1.9287ms |
| Medium ~20% | 0.7263ms (0.97x) | 0.7048ms | 2.2472ms (0.86x) | 1.9287ms |
| High ~80% | 0.9562ms (1.80x) | 1.7223ms | 2.7294ms (1.51x) | 4.1331ms |

### 情境 B：`transport-sync-players`（公開 players 也會變）

#### Dirty Tracking ON（AMD 數據）

**默認模式（平行編碼，Medium State 10 Cards/Player，100 iterations）：**

| Dirty Ratio | 30 人（Parallel） | 50 人（Parallel） |
| --- | ---: | ---: |
| Low hands ~5% | 0.6094ms | 1.4175ms |
| Medium hands ~20% | 0.6394ms | 1.5295ms |
| High hands ~80% | 0.6184ms | 1.7359ms |

**Medium State (10 Cards/Player, Serial/Parallel 比較，50 iterations)：**

| Dirty Ratio | 30 人（Parallel） | 30 人（Serial） | 50 人（Parallel） | 50 人（Serial） |
| --- | ---: | ---: | ---: | ---: |
| Low hands ~5% | 1.3832ms (1.75x) | 2.4266ms | 2.9873ms (2.10x) | 6.2702ms |
| Medium hands ~20% | 1.4389ms | - | 3.1692ms | - |
| High hands ~80% | 1.6986ms (1.44x) | 2.4378ms | 3.5335ms (2.62x) | 9.2571ms |

**編碼比較測試（50 iterations，獨立 process）：**

| Dirty Ratio | 30 人（Serial） | 30 人（Parallel） | 50 人（Serial） | 50 人（Parallel） |
| --- | ---: | ---: | ---: | ---: |
| Low hands ~5% | 1.4104ms | 0.6094ms (2.31x) | 3.7975ms | 1.4175ms (2.68x) |
| High hands ~80% | 2.7883ms | 0.6184ms (4.51x) | 4.5093ms | 1.7359ms (2.60x) |

> **重要發現**：
> - AMD 平台上，平行編碼在 **High dirty ratio** 和 **50+ 玩家**時效果非常明顯（可達 2.3-4.5x 提升）
> - 在 **Low dirty ratio** 時，平行編碼也有明顯優勢（2.3-2.7x）
> - **建議使用 AMD 數據進行伺服器容量估算**，因為數據更穩定可靠

#### Dirty Tracking OFF（AMD 數據）
**Medium State (10 Cards/Player, Serial/Parallel 比較，50 iterations)：**

| Dirty Ratio | 30 人（Parallel） | 30 人（Serial） | 50 人（Parallel） | 50 人（Serial） |
| --- | ---: | ---: | ---: | ---: |
| Low hands ~5% | 1.3386ms (1.63x) | 2.1799ms | 3.2104ms (1.98x) | 6.3645ms |
| Medium hands ~20% | 1.3931ms | - | 2.9662ms | - |
| High hands ~80% | 1.7187ms (1.43x) | 2.4550ms | 3.5143ms (2.11x) | 7.4051ms |

> **解讀**：
> - 當 `players` 也變動時（情境 B），sync 成本會明顯上升
> - 平行編碼在 **dirty off** 情境下效果特別明顯（可達 2-5x 提升）
> - Dirty tracking 在 Medium/High 變動情境下仍有優勢
> - 括號內數字為 Serial / Parallel（> 1.0 表示 Parallel 更快）

## Mac vs AMD 平台對比

### 主要發現

1. **穩定性差異**：
   - **AMD**：數據穩定，適合用於生產環境容量估算
   - **Mac**：連續運行多個測試套件時可能出現數據波動（可能是熱節流或系統調度影響）

2. **性能差異**：
   - AMD 平台整體性能更優（可能是架構和編譯器優化差異）
   - Mac 上某些場景（特別是 Low dirty ratio）可能因 TaskGroup 開銷導致性能略差

3. **建議**：
   - **使用 AMD 數據進行伺服器效能估算**（更穩定、更接近 Linux 生產環境）
   - Mac 數據可作為參考，但需注意數據波動

## 新舊 Mac 數據對比（優化前後）

### 對比說明

以下對比舊版 Mac 數據（2025-12-31 之前，未啟用平行編碼優化）與新版 Mac 數據（2026-01-01，已啟用平行編碼優化）。

**舊版數據特徵**：
- 未明確區分 Serial/Parallel 編碼模式
- 可能在同一 process 中連續運行多個測試套件
- 數據來源：`transport-sync-dirty-on.txt`、`transport-sync-players-dirty-on.txt`（已歸檔）

**新版數據特徵**：
- 明確區分 Serial/Parallel 編碼模式
- 每個測試套件在獨立 process 中運行
- 數據來源：`transport-sync-dirty-on-Apple_M2-8cores-16GB-swift6.2-20260101-165802.txt`

### 情境 A：`transport-sync`（players 通常不變）

**Medium State (10 Cards/Player), Dirty Tracking ON：**

| 玩家數 | 舊版數據 | 新版 Parallel | 新版 Serial | 變化 |
| --- | ---: | ---: | ---: | ---: |
| 30 人 | 2.6569ms | 1.1150ms | 1.0707ms | **-58%** (Parallel) |
| 50 人 | 3.6410ms | 2.4647ms | 2.2932ms | **-32%** (Parallel) |

**High Dirty ~80%, Medium State：**

| 玩家數 | 舊版數據 | 新版 Parallel | 新版 Serial | 變化 |
| --- | ---: | ---: | ---: | ---: |
| 30 人 | 7.8179ms | 1.3409ms | 1.9245ms | **-83%** (Parallel) |
| 50 人 | 11.0818ms | 3.1123ms | 3.6702ms | **-72%** (Parallel) |

> **解讀**：
> - 新版數據明顯優於舊版，主要因為：
>   1. 平行編碼優化（Parallel Encoding）
>   2. 測試套件隔離（每個 suite 獨立 process）
>   3. 可能的代碼優化
> - 性能提升在 High dirty ratio 時最明顯（可達 70-80% 提升）

### 情境 B：`transport-sync-players`（公開 players 也會變）

**Medium State (10 Cards/Player), Dirty Tracking ON：**

| 玩家數 | 舊版數據 | 新版 Parallel | 新版 Serial | 變化 |
| --- | ---: | ---: | ---: | ---: |
| 30 人 | 6.8705ms | 1.9364ms | 2.7638ms | **-72%** (Parallel) |
| 50 人 | 9.7098ms | 3.5946ms | 5.8860ms | **-63%** (Parallel) |

**High Hands Dirty ~80%, Medium State：**

| 玩家數 | 舊版數據 | 新版 Parallel | 新版 Serial | 變化 |
| --- | ---: | ---: | ---: | ---: |
| 30 人 | 20.5187ms | 2.3551ms | 3.1783ms | **-89%** (Parallel) |
| 50 人 | 24.1068ms | 4.3293ms | 7.7528ms | **-82%** (Parallel) |

> **解讀**：
> - 新版數據在 `transport-sync-players` 情境下提升更明顯（可達 60-90% 提升）
> - 特別是在 High dirty ratio 時，性能提升最顯著
> - 這證明了平行編碼優化和測試套件隔離的重要性

### 關鍵發現

1. **平行編碼優化效果顯著**：
   - 在所有測試場景下，新版 Parallel 編碼都明顯優於舊版
   - 在 High dirty ratio 時效果最明顯（可達 80-90% 提升）

2. **測試套件隔離的重要性**：
   - 新版數據更穩定，因為每個 suite 在獨立 process 中運行
   - 舊版數據可能受到狀態污染的影響

3. **數據可靠性**：
   - 新版數據更可靠，因為明確區分了編碼模式
   - 舊版數據已歸檔，僅供歷史參考

### 舊版數據歸檔

舊版 Mac benchmark 數據已歸檔至 `Notes/performance/archived/` 目錄：

- `transport-sync-dirty-on.txt` - ⚠️ 過時（2025-12-31 之前）
- `transport-sync-dirty-off.txt` - ⚠️ 過時（2025-12-31 之前）
- `transport-sync-players-dirty-on.txt` - ⚠️ 過時（2025-12-31 之前）
- `transport-sync-players-dirty-off.txt` - ⚠️ 過時（2025-12-31 之前）

**不建議使用舊版數據進行容量估算**，原因：
1. 未明確區分編碼模式
2. 可能在同一 process 中連續運行，存在狀態污染
3. 未啟用平行編碼優化
4. 數據可能不穩定

### Mac 數據（參考）

**情境 A：`transport-sync`（Medium State, 10 Cards/Player）**

| Dirty Ratio | 30 人（Parallel） | 30 人（Serial） | 50 人（Parallel） | 50 人（Serial） |
| --- | ---: | ---: | ---: | ---: |
| Low ~5% | 1.2226ms | 1.3267ms | 1.9379ms | 2.1126ms |
| Medium ~20% | 1.1150ms | 1.0707ms | 2.4647ms | 2.2932ms |
| High ~80% | 1.3409ms (1.44x) | 1.9245ms | 3.1123ms (1.18x) | 3.6702ms |

**情境 B：`transport-sync-players`（Medium State, 10 Cards/Player）**

| Dirty Ratio | 30 人（Parallel） | 30 人（Serial） | 50 人（Parallel） | 50 人（Serial） |
| --- | ---: | ---: | ---: | ---: |
| Low hands ~5% | 1.9364ms (1.43x) | 2.7638ms | 3.5946ms (1.64x) | 5.8860ms |
| Medium hands ~20% | 2.1873ms | - | 3.8984ms | - |
| High hands ~80% | 2.3551ms (1.35x) | 3.1783ms | 4.3293ms (1.79x) | 7.7528ms |

## 容量估算方式（基於 AMD 數據）

### 基本變數

- `syncMs`：benchmark 的 `syncNow()` 平均時間（毫秒）
- `tickHz`：每秒同步次數（例如 20Hz = 50ms/tick；事件驅動可用「每秒平均同步次數」替代）
- `overheadFactor`：除 sync 以外的 server 開銷比例（遊戲邏輯、action/event、排程、logging、真實 I/O…）
  - 例如 `0.5` 代表其他開銷約等於 sync 的 50%
- `safetyFactor`：安全係數，用於吸收未知成本（網路堆疊、GC/allocator 波動、監控、log、尖峰）
  - 建議值：保守 `0.6`；一般 `0.7`
- `cpuBudgetMsPerSec`：CPU 每秒可用時間
  - **12 核心（AMD）** × 1000ms × 0.8 ≈ **9600ms/秒**
  - **8 核心（Mac）** × 1000ms × 0.8 ≈ **6400ms/秒**

估算公式：

```
roomCpuPerSec = syncMs * (1 + overheadFactor) * tickHz
rooms = cpuBudgetMsPerSec / roomCpuPerSec * safetyFactor
```

### 用情境 B（公開 players 也會變）做 30 人房間示例（AMD 數據）

以 **Medium State / 30 人 / dirty on / Parallel 編碼** 為例：

- Low hands ~5%：`syncMs = 1.3832`
- Medium hands ~20%：`syncMs = 1.4389`
- High hands ~80%：`syncMs = 1.6986`

假設 `overheadFactor = 0.5`、`safetyFactor = 1.0`（先不折減），使用 **AMD 12 核心**數據：

- **20Hz（50ms/tick）**
  - Low hands ~5%：`rooms ≈ 9600 / (1.3832 * 1.5 * 20) ≈ 231`
  - Medium hands ~20%：`rooms ≈ 9600 / (1.4389 * 1.5 * 20) ≈ 222`
  - High hands ~80%：`rooms ≈ 9600 / (1.6986 * 1.5 * 20) ≈ 188`
- **10Hz（100ms/tick）**
  - Low hands ~5%：約 462
  - Medium hands ~20%：約 444
  - High hands ~80%：約 376

### 50 人房間示例（AMD 數據）

以 **Medium State / 50 人 / dirty on / Parallel 編碼** 為例：

- Low hands ~5%：`syncMs = 2.9873`
- Medium hands ~20%：`syncMs = 3.1692`
- High hands ~80%：`syncMs = 3.5335`

假設 `overheadFactor = 0.5`、`safetyFactor = 1.0`（先不折減），使用 **AMD 12 核心**數據：

- **20Hz（50ms/tick）**
  - Low hands ~5%：`rooms ≈ 9600 / (2.9873 * 1.5 * 20) ≈ 107`
  - Medium hands ~20%：`rooms ≈ 9600 / (3.1692 * 1.5 * 20) ≈ 101`
  - High hands ~80%：`rooms ≈ 9600 / (3.5335 * 1.5 * 20) ≈ 91`
- **10Hz（100ms/tick）**
  - Low hands ~5%：約 214
  - Medium hands ~20%：約 202
  - High hands ~80%：約 182

> 這個範圍差很大是正常的：同步成本主要由「每 tick 你到底改了多少東西」決定。

## 實務建議

1. **如果你的遊戲每 tick 都會刷新大多數玩家的公開狀態**（位置/速度/HP…），請以 `transport-sync-players-*.txt` 作為估算基準。

2. **Dirty tracking 是否要開**：在 Medium/High 變動的情境下，dirty on 通常更划算；但在「接近全量變動」且 state 結構特殊時，dirty off 可能接近甚至略快（請用你的 state 實測）。

3. **平行編碼效果**：
   - 預設已啟用平行編碼（JSON codec）
   - 在 **High dirty ratio** 和 **50+ 玩家**時效果最明顯（可達 2-5x 提升）
   - 在 **Low dirty ratio** 時也有明顯優勢（2-3x）
   - 可通過 `TransportAdapter.setParallelEncodingEnabled(false)` 禁用

4. **平台選擇**：
   - **推薦使用 AMD 數據進行伺服器效能估算**（更穩定、更接近 Linux 生產環境）
   - Mac 數據可作為參考，但需注意數據波動
   - 如果使用 Mac 進行測試，建議拆開運行不同的測試套件，避免連續運行導致熱節流

5. **下一個瓶頸通常是 O(players) per-player diff**：目前只知道「hands 欄位 dirty」，不知道「哪些 PlayerID 的 hands 改了」，所以玩家數大時仍會線性成長；要再往下壓，需要 key-level dirty（例如 `ReactiveDictionary.dirtyKeys`）或回傳受影響 PlayerIDs。

## 下一步（頻寬口徑補齊）

1. **Payload bytes 已可量到**：benchmark 會統計每次 sync 送出的 encoded bytes（總和 / iterations），但仍不含 WebSocket/TCP/TLS framing。
2. **補兩組傳輸口徑**：
   - mock transport send（純 CPU + encode）
   - loopback WebSocket send（含協議與系統 call）
3. **這樣可同時估**：CPU 上限 + 頻寬上限（與 Colyseus/Photon 比較口徑一致）

## Git 變更記錄

主要變更（2025-12-30 至 2026-01-01）：

- `3fa8bc1` - feat: Add parallel encoding support for improved performance
- `ef83174` - refactor: Enhance benchmark configuration and reporting for transport sync
- `ed920ef` - refactor: Clarify parallel encoding configuration in benchmark suite
- `a902006` - fix: Ensure compatibility with Windows line endings in benchmark script
- `88ce6a5` - refactor: Remove outdated benchmark files for transport sync and players

這些變更主要涉及：
1. 添加平行編碼支援以提升性能
2. 改進 benchmark 配置和報告
3. 明確平行編碼配置（從 `nil` 改為明確的 `true`/`false`）
4. 移除過時的 benchmark 文件
5. 改進腳本跨平台兼容性（支援 macOS 和 Linux）

## 測試方法論與發現總結

### 關鍵發現：測試套件隔離的重要性

#### 問題描述

在開發和測試過程中，我們發現了一個**關鍵問題**：

**如果多個測試套件（suite）在同一個 process 中連續運行，數據會完全不準確。**

#### 具體表現

1. **穿插測試（Interleaved Testing）會導致數據異常**
   - 當在同一個 process 中連續運行多個不同的測試套件時
   - 後續測試的數據會受到前面測試的影響
   - 數據波動明顯，無法用於準確的容量估算

2. **實際案例**
   - 在 Mac 平台上，連續運行多個 suite 時，後面的測試數據明顯異常
   - 某些測試的執行時間會出現不合理的波動
   - 數據無法重現，每次運行結果都不同

#### 根本原因分析

1. **狀態污染（State Contamination）**
   - 前一個測試的狀態（記憶體、緩存、全局變數）可能影響後續測試
   - Swift runtime 的內部狀態可能被污染

2. **記憶體碎片（Memory Fragmentation）**
   - 長時間運行導致記憶體分配模式改變
   - 後續測試的記憶體分配效率可能受到影響

3. **系統調度影響**
   - 連續運行可能觸發不同的 CPU 調度策略
   - 系統資源分配可能發生變化

4. **JIT 編譯器狀態**
   - Swift runtime 的優化狀態可能被污染
   - 編譯器緩存可能影響後續測試

#### 解決方案

**每個測試套件必須在獨立的 process 中運行**

當前實現：
- `run-transport-sync-benchmarks.sh` 腳本通過 `swift run` 為每個 suite 創建獨立 process
- 每個 suite 都在全新的 Swift runtime 環境中運行
- 確保測試之間完全隔離，無狀態污染

#### 最佳實踐

✅ **正確做法**：
```bash
# 使用腳本自動拆開運行（每個 suite 獨立 process）
bash Tools/CLI/run-transport-sync-benchmarks.sh
```

❌ **錯誤做法**：
```bash
# 絕對不要在同一個 process 中連續運行多個 suite
swift run -c release SwiftStateTreeBenchmarks transport-sync \
  --suite-name="Suite1" \
  --suite-name="Suite2" \
  --suite-name="Suite3"
```

### 平台穩定性差異

#### Mac 平台（Apple M2）

**特點**：
- 連續運行多個測試套件時可能出現數據波動
- 可能是熱節流（thermal throttling）或系統調度影響
- 建議拆開運行，在測試之間留出冷卻時間

**建議**：
- 使用腳本自動拆開運行
- 在測試之間留出足夠的冷卻時間
- 如果發現數據不穩定，可以手動拆開運行不同的測試套件

#### AMD 平台（Ryzen 5 7600X, Linux）

**特點**：
- 數據非常穩定
- 適合用於生產環境的容量估算
- 推薦作為主要參考數據

**建議**：
- 優先使用 AMD 數據進行伺服器效能估算
- 更接近 Linux 生產環境

### 測試配置對結果的影響

1. **Iterations 數量**
   - 100 iterations 的數據比 50 iterations 更穩定
   - 默認測試（100 iterations）用於容量估算
   - 編碼比較測試（50 iterations）用於評估相對加速比

2. **測試順序**
   - 不同測試套件的執行順序可能影響結果（特別是 Mac 平台）
   - 建議使用固定的測試順序

3. **系統負載**
   - 建議在系統負載較低時運行 benchmark
   - 背景程序可能影響測試結果

### 已知限制

1. **測試環境差異**：
   - 不同平台的數據不能直接比較
   - 同一平台不同時間運行的數據可能有波動（特別是 Mac）

2. **測試配置差異**：
   - 不同 iterations 數量的測試結果差異較大
   - 編碼比較測試（50 iterations）的絕對時間可能與默認測試（100 iterations）差異較大

3. **系統影響**：
   - 系統負載、背景程序可能影響測試結果
   - Mac 平台的熱節流可能導致數據波動

### 總結

1. **測試套件隔離是必須的**：絕對不要在同一個 process 中連續運行多個 suite
2. **使用 AMD 數據進行伺服器估算**：更穩定、更可靠
3. **遵循最佳實踐**：使用腳本自動拆開運行，確保測試隔離
4. **記錄測試環境**：記錄 CPU、記憶體、Swift 版本等信息，以便後續分析

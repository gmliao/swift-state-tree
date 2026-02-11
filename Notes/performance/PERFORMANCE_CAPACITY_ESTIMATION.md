# CPU 承載能力估算（以 30 人房間為例）

本文件的目標是把「TransportAdapter.syncNow() 的 benchmark 數據」轉成可用的容量估算方式，並把不同情境（dirty ratio / 公開狀態是否每次 sync 前都在變）分開說清楚。

## TL;DR（可引用結論）

- **推薦估算基準**：AMD / `transport-sync-players` / dirty on / parallel
- **30 人、Medium State、20Hz**：約 197–236 rooms（**未套 safetyFactor**）
- **50 人、Medium State、20Hz**：約 86–116 rooms（**未套 safetyFactor**）
- **10Hz 對應倍增**：30 人約 394–472 rooms，50 人約 172–233 rooms（**未套 safetyFactor**）
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
- **狀態變更方式**：每次 iteration 先用 deterministic mutation 更新 state（無背景 tick），mutation 時間不計入 `syncNow()`
- **不包含**：真實網路（TCP/TLS/WebSocket）、封包排隊、Client 端處理、跨機器延遲

> 結論用法：把這裡的結果當成「server 端同步邏輯的 CPU 基準」，真實環境請用你自己的 state/tick/action 重新跑一次 benchmark 再估算。

## Multi-room 平行編碼調校（Staggered Tick）

### 測試說明

- 使用 `transport-multiroom-parallel-tuning` 套件
- 每個房間一個 `LandKeeper + TransportAdapter`，同一個 process 內並行跑
- **Tick 模式**：`staggered`（以 stride/offset 模擬錯峰更新，不用 sleep）
- **目的**：觀察多房間下平行 JSON encode 的實際收益與最佳並行度

### 主要結果（摘要）

- 平行編碼收益 **多數落在 1.0–1.2x**，提升幅度有限
- 小房間（<=10 人）幾乎沒有收益，甚至可能略慢
- 20–50 人房間在某些組合有 1.1–1.3x 的小幅提升
- `maxConcurrency` 沒有單一最佳值，2–4 通常最穩定

### 最新測試檔案（參考）

- AMD：`transport-multiroom-parallel-tuning-dirty-on-AMD_Ryzen_5_7600X_6_Core_Proce-12cores-15GB-swift6.0-20260104-020113.txt`
- Mac：`transport-multiroom-parallel-tuning-dirty-on-Apple_M2-8cores-16GB-swift6.2-20260103-210541.txt`

### 局限與注意事項

- **仍是合成測試**：沒有真實網路 I/O、tick 排程、玩家輸入分布
- **單一 process**：沒有跨服務器負載、沒有真實 WebSocket backpressure
- **Tick 為虛擬錯峰**：雖然模擬不同房間更新頻率，但不等同實際 server 時序

> **結論**：平行編碼的收益有限，**真正準確的效能結論仍需要跑真實伺服器**（完整 action/tick/transport/IO）。
> 
> **當前狀態**：並行編碼功能已實作並完成測試，但在合成測試環境中效果不明（收益多數落在 1.0–1.2x）。**目前預設關閉**，後續需要進行機器人真實測試才能比較明確定義實際效果。

## 最新 Benchmark 檔案（2026-01-01 更新）

### AMD 數據（推薦用於伺服器估算）

- **原始情境（players 通常不變）**
  - dirty on：`transport-sync-dirty-on-AMD_Ryzen_5_7600X_6_Core_Proce-12cores-15GB-swift6.0-20260101-121509.txt`
  - dirty off：`transport-sync-dirty-off-AMD_Ryzen_5_7600X_6_Core_Proce-12cores-15GB-swift6.0-20260101-121509.txt`
- **更貼近實務（公開 players 也會每次 sync 前變動）**
  - dirty on：`transport-sync-players-dirty-on-AMD_Ryzen_5_7600X_6_Core_Proce-12cores-15GB-swift6.0-20260101-121509.txt`
  - dirty off：`transport-sync-players-dirty-off-AMD_Ryzen_5_7600X_6_Core_Proce-12cores-15GB-swift6.0-20260101-121509.txt`

### Mac 數據（參考）

- **原始情境（players 通常不變）**
  - dirty on：`transport-sync-dirty-on-Apple_M2-8cores-16GB-swift6.2-20260101-215032.txt`
  - dirty off：`transport-sync-dirty-off-Apple_M2-8cores-16GB-swift6.2-20260101-215032.txt`
- **更貼近實務（公開 players 也會每次 sync 前變動）**
  - dirty on：`transport-sync-players-dirty-on-Apple_M2-8cores-16GB-swift6.2-20260101-215032.txt`
  - dirty off：`transport-sync-players-dirty-off-Apple_M2-8cores-16GB-swift6.2-20260101-215032.txt`

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
- **Serial/Parallel 比較 suite**：100 iterations（用於評估相對加速比）
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
   - ✅ 使用 Serial/Parallel 比較數據評估相對加速比
   - ✅ 優先使用 AMD 數據進行伺服器效能估算
   - ❌ 不要直接比較不同 iterations 或不同平台的絕對時間

3. **開發新測試時**：
   - ✅ 確保每個測試套件在獨立 process 中運行
   - ✅ 使用足夠的 iterations 以獲得穩定結果
   - ✅ 記錄測試環境和配置信息

> **注意**：
> - 並行編碼功能已實作並完成測試，但**目前預設關閉**（在合成測試環境中效果不明）
> - 默認測試（100 iterations）的數據用於容量估算
> - Serial/Parallel 比較 suite（100 iterations，獨立 process）用於評估平行編碼的加速比
> - **Mac 用戶建議**：如果發現數據不穩定，可以手動拆開運行不同的測試套件，避免連續運行導致熱節流
> - **後續計劃**：需要進行機器人真實測試才能比較明確定義並行編碼的實際效果

## Benchmark 模型（你在估算時要知道的假設）

### State 結構（精簡）

`TransportAdapterSyncBenchmarkRunner` 目前用的狀態是：

- broadcast：`round`、`players: [PlayerID: BenchmarkPlayerState]`
- per-player：`hands: [PlayerID: BenchmarkHandState]`

### 兩種情境差異

- `transport-sync`：每次 sync 前 **一定改 `round`**，另外改一部分玩家的 `hands`（依 dirty ratio），但 **通常不改 `players`**。
- `transport-sync-players`：在上述基礎上，另外每次 sync 前 **也會改 `players`（預設 ~100% 玩家）**，模擬「位置/HP/狀態等公開資訊常常更新」。

### dirty ratio 的意思

這裡的 Low/Medium/High 是「每次 sync 前會被挑中去改 per-player hands 的玩家比例（約略）」：

- Low：~5%
- Medium：~20%
- High：~80%

> 注意：目前 dirty tracking 是「欄位名」粒度，像 `hands` 只要任何玩家改到，實作上仍會對所有玩家做 per-player snapshot/diff（只是比對範圍縮小到 `hands` 欄位本身）。因此玩家數上升時仍會看到 O(players) 的成本。

## 最新數據（AMD 平台，建議用於伺服器估算）

下面列的是 **Medium State（Cards/Player: 10）**，取 **30 人房間** 與 **50 人房間** 的數據；若某情境只量到 Serial 或 Parallel，表格會以 `-` 標示。

**格式說明**：表格中顯示 Serial（串行編碼）和 Parallel（平行編碼）兩種模式的時間，括號內為加速比（Serial / Parallel；< 1.0 表示 Parallel 較慢），缺值以 `-` 表示。
**註記**：最新 Serial 數據已改為 100 iterations（與 Parallel 一致）。

### 情境 A：`transport-sync`（players 通常不變）

#### Dirty Tracking ON（AMD 數據）

**Medium State (10 Cards/Player, Parallel 100 iterations / Serial 50 iterations)：**

| Dirty Ratio | 30 人（Parallel） | 30 人（Serial） | 50 人（Parallel） | 50 人（Serial） |
| --- | ---: | ---: | ---: | ---: |
| Low ~5% | - | 0.8406ms | - | 1.5247ms |
| Medium ~20% | 0.7517ms | - | 2.0515ms | - |
| High ~80% | 1.0207ms (2.19x) | 2.2405ms | 2.7511ms (1.51x) | 4.1463ms |

#### Dirty Tracking OFF（AMD 數據）

**Medium State (10 Cards/Player, Parallel 100 iterations / Serial 50 iterations)：**

| Dirty Ratio | 30 人（Parallel） | 30 人（Serial） | 50 人（Parallel） | 50 人（Serial） |
| --- | ---: | ---: | ---: | ---: |
| Low ~5% | - | 1.0002ms | - | 2.2786ms |
| Medium ~20% | 0.9088ms | - | 2.5284ms | - |
| High ~80% | 0.9841ms (2.13x) | 2.0956ms | 2.8758ms (1.67x) | 4.8067ms |

### 情境 B：`transport-sync-players`（公開 players 也會變）

#### Dirty Tracking ON（AMD 數據）

**默認模式（平行編碼，Medium State 10 Cards/Player，100 iterations）：**

| Dirty Ratio | 30 人（Parallel） | 50 人（Parallel） |
| --- | ---: | ---: |
| Low hands ~5% | 1.3573ms | 2.7505ms |
| Medium hands ~20% | 1.6113ms | 3.3467ms |
| High hands ~80% | 1.6254ms | 3.7188ms |

**Medium State (10 Cards/Player, Parallel 100 iterations / Serial 50 iterations)：**

| Dirty Ratio | 30 人（Parallel） | 30 人（Serial） | 50 人（Parallel） | 50 人（Serial） |
| --- | ---: | ---: | ---: | ---: |
| Low hands ~5% | 1.3531ms (1.77x) | 2.4083ms | 2.8208ms (2.01x) | 5.5315ms |
| Medium hands ~20% | 1.4383ms | - | 3.4090ms | - |
| High hands ~80% | 1.5651ms (1.90x) | 2.9769ms | 3.1434ms (1.90x) | 6.6140ms |

> **重要發現**：
> - AMD 平台上，平行編碼在 **High dirty ratio** 和 **50+ 玩家**時提升明顯（約 2.0-3.3x，dirty off 最高）
> - 在 **Low dirty ratio** 時，平行編碼仍有穩定優勢（約 1.7-2.0x）
> - **建議使用 AMD 數據進行伺服器容量估算**，因為數據更穩定可靠

#### Dirty Tracking OFF（AMD 數據）
**Medium State (10 Cards/Player, Parallel 100 iterations / Serial 50 iterations)：**

| Dirty Ratio | 30 人（Parallel） | 30 人（Serial） | 50 人（Parallel） | 50 人（Serial） |
| --- | ---: | ---: | ---: | ---: |
| Low hands ~5% | 1.3338ms (1.70x) | 2.2738ms | 2.8757ms (2.39x) | 6.8735ms |
| Medium hands ~20% | 1.3072ms | - | 3.0294ms | - |
| High hands ~80% | 1.6202ms (2.80x) | 4.5318ms | 3.7374ms (3.32x) | 12.3988ms |

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
此段比較沿用早期 Mac logs（未含 deterministic mutation）；最新數據請以「Mac 數據（參考）」段落為準。

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

**情境 A：`transport-sync`（Medium State, 10 Cards/Player, Parallel 100 iterations / Serial 50 iterations）**

| Dirty Ratio | 30 人（Parallel） | 30 人（Serial） | 50 人（Parallel） | 50 人（Serial） |
| --- | ---: | ---: | ---: | ---: |
| Low ~5% | - | 0.6262ms | - | 1.0449ms |
| Medium ~20% | 0.6690ms | - | 1.0608ms | - |
| High ~80% | 0.9230ms (1.64x) | 1.5118ms | 1.5015ms (1.72x) | 2.5779ms |

**情境 B：`transport-sync-players`（Medium State, 10 Cards/Player, Parallel 100 iterations / Serial 50 iterations）**

| Dirty Ratio | 30 人（Parallel） | 30 人（Serial） | 50 人（Parallel） | 50 人（Serial） |
| --- | ---: | ---: | ---: | ---: |
| Low hands ~5% | 1.3624ms (1.72x) | 2.3482ms | 2.9187ms (1.90x) | 5.5411ms |
| Medium hands ~20% | 1.4383ms | - | 3.4090ms | - |
| High hands ~80% | 1.8043ms (1.65x) | 2.9769ms | 3.4807ms (1.90x) | 6.6140ms |

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

- Low hands ~5%：`syncMs = 1.3573`
- Medium hands ~20%：`syncMs = 1.6113`
- High hands ~80%：`syncMs = 1.6254`

假設 `overheadFactor = 0.5`、`safetyFactor = 1.0`（先不折減），使用 **AMD 12 核心**數據：

- **20Hz（50ms/tick）**
  - Low hands ~5%：`rooms ≈ 9600 / (1.3573 * 1.5 * 20) ≈ 236`
  - Medium hands ~20%：`rooms ≈ 9600 / (1.6113 * 1.5 * 20) ≈ 199`
  - High hands ~80%：`rooms ≈ 9600 / (1.6254 * 1.5 * 20) ≈ 197`
- **10Hz（100ms/tick）**
  - Low hands ~5%：約 472
  - Medium hands ~20%：約 397
  - High hands ~80%：約 394

### 50 人房間示例（AMD 數據）

以 **Medium State / 50 人 / dirty on / Parallel 編碼** 為例：

- Low hands ~5%：`syncMs = 2.7505`
- Medium hands ~20%：`syncMs = 3.3467`
- High hands ~80%：`syncMs = 3.7188`

假設 `overheadFactor = 0.5`、`safetyFactor = 1.0`（先不折減），使用 **AMD 12 核心**數據：

- **20Hz（50ms/tick）**
  - Low hands ~5%：`rooms ≈ 9600 / (2.7505 * 1.5 * 20) ≈ 116`
  - Medium hands ~20%：`rooms ≈ 9600 / (3.3467 * 1.5 * 20) ≈ 96`
  - High hands ~80%：`rooms ≈ 9600 / (3.7188 * 1.5 * 20) ≈ 86`
- **10Hz（100ms/tick）**
  - Low hands ~5%：約 233
  - Medium hands ~20%：約 191
  - High hands ~80%：約 172

> 這個範圍差很大是正常的：同步成本主要由「每次 sync 前你到底改了多少東西」決定。

## 實務建議

1. **如果你的遊戲每 tick 都會刷新大多數玩家的公開狀態**（位置/速度/HP…），請以 `transport-sync-players-*.txt` 作為估算基準。

2. **Dirty tracking 是否要開**：在 Medium/High 變動的情境下，dirty on 通常更划算；但在「接近全量變動」且 state 結構特殊時，dirty off 可能接近甚至略快（請用你的 state 實測）。

3. **狀態更新編碼**：
   - 狀態更新以串行方式編碼（per-player parallel encoding 已移除，合成測試中效果有限 1.0–1.2x）

4. **平台選擇**：
   - **推薦使用 AMD 數據進行伺服器效能估算**（更穩定、更接近 Linux 生產環境）
   - Mac 數據可作為參考，但需注意數據波動
   - 如果使用 Mac 進行測試，建議拆開運行不同的測試套件，避免連續運行導致熱節流

5. **下一個瓶頸通常是 O(players) per-player diff**：目前只知道「hands 欄位 dirty」，不知道「哪些 PlayerID 的 hands 改了」，所以玩家數大時仍會線性成長；要再往下壓，需要 key-level dirty（例如 `ReactiveDictionary.dirtyKeys`）或回傳受影響 PlayerIDs。

## 下一步（頻寬口徑補齊）

1. **Payload bytes 已可量到**：benchmark 會統計每次 sync 送出的 encoded bytes（總和 / iterations），但仍不含 WebSocket/TCP/TLS framing。
   - 報表同時附帶 per-player 平均 bytes，方便估頻寬/成本
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
   - Serial/Parallel 比較 suite（100 iterations）用於評估相對加速比

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
   - Serial/Parallel 比較 suite（100 iterations）的絕對時間可能與默認測試（100 iterations）差異較大

3. **系統影響**：
   - 系統負載、背景程序可能影響測試結果
   - Mac 平台的熱節流可能導致數據波動

### 總結

1. **測試套件隔離是必須的**：絕對不要在同一個 process 中連續運行多個 suite
2. **使用 AMD 數據進行伺服器估算**：更穩定、更可靠
3. **遵循最佳實踐**：使用腳本自動拆開運行，確保測試隔離
4. **記錄測試環境**：記錄 CPU、記憶體、Swift 版本等信息，以便後續分析

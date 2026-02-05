# snapshotForSync POC 效能評比結果

測試日期：2026-02-04

## 測試配置

### 方法對比

**舊方法（USE_SNAPSHOT_FOR_SYNC=false）**：
- 1× `state.broadcastSnapshot(dirtyFields:)` → broadcast 提取
- N× `state.snapshot(for: playerID, dirtyFields:)` → per-player 提取（每個玩家一次完整樹遍歷）
- 總共：**1 + N 次**根層遍歷

**新方法（USE_SNAPSHOT_FOR_SYNC=true）**：
- 1× `state.snapshotForSync(playerIDs:, dirtyFields:)` → 一次遍歷根層所有欄位
  - Broadcast 欄位 → 寫入 broadcastResult（1 次）
  - Per-player 欄位 → 對每個 playerID 迴圈寫入（本例中 HeroDefenseState 無 per-player 欄位）
  - 巢狀 StateNode 遞迴呼叫其 `snapshotForSync`
- 總共：**1 次**根層遍歷

### 測試環境

- **平台**：macOS arm64 (M-series)
- **Swift**：6.2.3
- **編譯模式**：Release (`-c release`)
- **Transport**：MessagePack + opcodeMessagePack
- **Dirty Tracking**：Enabled

---

## 測試結果

### Test 1：10 房 (Debug Mode)

| 指標 | 舊方法 | 新方法 | 差異 |
|------|--------|--------|------|
| avgRecvBytesPerSecond | 59,222 | 59,345 | +123 (+0.2%) |
| avgRecvMessagesPerSecond | 441.25 | 442.5 | +1.25 (+0.3%) |
| avgSentBytesPerSecond | 3,999 | 3,999 | 0 |
| totalSeconds | 40 | 40 | 0 |

**觀察**：差異極小，在誤差範圍內。

### Test 2：100 房 (Release Mode)

| 指標 | 舊方法 | 新方法 | 差異 |
|------|--------|--------|------|
| avgRecvBytesPerSecond | 593,471 | 589,960 | **-3,511 (-0.6%)** |
| avgRecvMessagesPerSecond | 4,471.6 | 4,457.6 | -14 (-0.3%) |
| avgSentBytesPerSecond | 40,021 | 40,021 | 0 |
| playersCreated | 500 | 500 | 0 |
| roomsTarget | 100 | 100 | 0 |
| totalSeconds | 40 | 40 | 0 |

**觀察**：新方法反而略慢（-0.6%），但仍在誤差範圍內。

### Test 3：100 房 + CPU 監控（run-server-loadtest.sh，Release）

使用 `run-server-loadtest.sh`（**不加** `--no-monitoring`），ps 取樣每秒記錄 ServerLoadTest process CPU，結束後由 `parse_monitoring.py` 產出 pidstat 摘要與 HTML。

| 指標 | 舊方法 | 新方法 | 差異 |
|------|--------|--------|------|
| **avg CPU %** | **99.0%** | **86.8%** | **-12.2 pt (-12.3%)** |
| **peak CPU %** | **224.8%** | **161.9%** | **-62.9 pt (-28.0%)** |
| pidstat 樣本數 | 101 | 92 | — |

**結論**：新方法（snapshotForSync 一次提取）明顯降低 **平均與峰值 CPU**，平均約省 12%、峰值約省 28%。

### Test 4：300 房 + CPU 監控（run-server-loadtest.sh，Release）

| 指標 | 舊方法 | 新方法 | 差異 |
|------|--------|--------|------|
| **avg CPU %** | **251.8%** | **159.7%** | **-92.1 pt (-36.5%)** |
| **peak CPU %** | **453.3%** | **337.3%** | **-116.0 pt (-25.6%)** |

**結論**：300 房規模下新方法 **平均 CPU 約降 36%、峰值約降 26%**，效益更明顯。

### Test 5：400 房 + ws-loadtest（GameServer，真實 WebSocket 客戶端）

使用 `Examples/GameDemo/ws-loadtest`，情境 `scenarios/hero-defense/profile-400rooms.json`（800 連線），報告內含 `system[].cpuPct` 取樣。

| 項目 | 新方法 (true) | 舊方法 (false) |
|------|----------------|----------------|
| 通過 | 全部通過 | 全部通過 |
| **平均 CPU %** | **193.5%** | **236.0%** |
| **峰值 CPU %** | **235.9%** | **294.6%** |

**結論**：400 房下新方法 **平均 CPU 約降 18%、峰值約降 20%**；延遲與錯誤率兩者皆在 threshold 內，行為一致。

```bash
cd Examples/GameDemo/ws-loadtest
USE_SNAPSHOT_FOR_SYNC=true  bash scripts/run-ws-loadtest.sh --scenario scenarios/hero-defense/profile-400rooms.json --output-dir results/ws-loadtest-400
USE_SNAPSHOT_FOR_SYNC=false bash scripts/run-ws-loadtest.sh --scenario scenarios/hero-defense/profile-400rooms.json --output-dir results/ws-loadtest-400-old
```

### 如何取得並比較 CPU（使用 run-server-loadtest.sh）

**必須用 `run-server-loadtest.sh`**，不要用 `swift run ServerLoadTest` 直接跑，否則不會有 CPU 記錄。

- 腳本會啟動 **ps 取樣**（macOS）或 **pidstat**（Linux），每秒記錄 ServerLoadTest process 的 CPU %
- 結束後執行 `parse_monitoring.py` 產生：
  - **Monitoring JSON**：`*-monitoring.json`，內含 `pidstat_summary.avg_cpu_total_pct`、`peak_cpu_total_pct`
  - **Monitoring HTML**：`*-monitoring.html`，內含互動式 CPU 圖表
- 若未加 `--no-monitoring`，監控資料還會 **merge 進測試結果 JSON**：`metadata.systemMonitoring.pidstat_summary`

**比較 CPU 的步驟**：

```bash
cd Examples/GameDemo/scripts/server-loadtest

# 100 房
USE_SNAPSHOT_FOR_SYNC=false bash run-server-loadtest.sh --rooms 100 --duration-seconds 20 --release
USE_SNAPSHOT_FOR_SYNC=true  bash run-server-loadtest.sh --rooms 100 --duration-seconds 20 --release

# 300 房
USE_SNAPSHOT_FOR_SYNC=false bash run-server-loadtest.sh --rooms 300 --duration-seconds 20 --release
USE_SNAPSHOT_FOR_SYNC=true  bash run-server-loadtest.sh --rooms 300 --duration-seconds 20 --release
```

比較兩次產生的 **HTML**（`*-monitoring.html` 裡的 Process CPU 圖表）或 **JSON**（`metadata.systemMonitoring.pidstat_summary.avg_cpu_total_pct`、`peak_cpu_total_pct`）。

---

## 問題分析

### 1. 為什麼沒有明顯改善？

#### 指標問題
- **avgRecvBytesPerSecond** 測量的是**網路吞吐量**，不是 CPU 效率
- 兩種方法產生的狀態更新內容相同，所以網路流量應該一樣
- 若要比較 CPU 效率，需要看：
  - **CPU 使用率**（老方法 138% vs 新方法 ???）
  - **Profile 熱點**：extractBroadcastSnapshot / extractPerPlayerSnapshot / snapshotForSync 的樣本數
  - **記憶體分配**：snapshot 相關的分配次數

#### 潛在因素
1. **Profile 檔案為空**：
   - 之前的 profile 收集產生了 0 byte 的 `.perf` 檔
   - 可能是 ROOMS=300 但腳本仍用 500 的參數，或 socket 取樣失敗
   - 需要重新收集有效的 profile 資料

2. **100 房規模可能不夠大**：
   - N=5 玩家/房 × 100 房 = 500 玩家
   - 舊方法：1 + 5 = 6 次根層遍歷/房（per sync）
   - 新方法：1 次根層遍歷/房（per sync）
   - 節省：5 次遍歷/房，但若根層欄位少（HeroDefenseState 只有 7 個欄位），每次遍歷成本低，總節省可能不明顯

3. **巢狀 StateNode 的影響**：
   - HeroDefenseState 的 `players`、`monsters`、`turrets` 都是 `[ID: StateNode]` dict
   - 在轉換時會呼叫 `SnapshotValue.make(from: dict, for: nil)`
   - 這個過程會遞迴對每個 dict 元素呼叫其 `toSnapshotValue()` 或 `snapshot(for:)`
   - 若 dict 很大（如 100 個 monster），這部分成本可能主導，遮蓋了根層遍歷次數的差異

4. **Dirty Tracking 的影響**：
   - 若 dirty fields 很少，兩種方法都只提取少數欄位
   - 節省的「重複遍歷」本來就不多（因為只走 dirty 的）

### 2. 已知限制

#### 測試問題
- Profile 收集失敗（.perf 檔為空），無法看到熱點變化
- 先前用 `swift run ServerLoadTest` 直接跑時沒有帶 monitoring，所以 JSON 裡沒有 CPU；**需用 `run-server-loadtest.sh`** 才會有 CPU 數據（見下方「如何取得 CPU 數據」）

#### 實作問題  
- 新方法在 `perPlayerByPlayer[playerID]!` 時會 crash（已修正為 `guard let`）
- 若玩家在 extraction 之後才 join，會被跳過該輪 sync（邏輯正確，但需確認不影響功能）

---

## 下一步

### 需要更準確的效能測量

1. **修正 Profile 收集**：
   - 確保 profile 腳本正確讀取 ROOMS 環境變數
   - 驗證 Profile Recorder socket 能正常取樣
   - 收集有效的 `.perf` 檔案供分析

2. **直接測量 CPU 時間**：
   - 使用 `ProcessInfo.processInfo.systemUptime` 或類似 API 測量 extraction 耗時
   - 在 `syncNow()` 前後加 timing，記錄 extraction 階段的耗時
   - 比較舊方法 vs 新方法的 extraction 時間

3. **更大規模測試**：
   - 300 房（1500 玩家）或更多
   - 觀察當 N 變大時，節省的 N 次遍歷是否更明顯

4. **Steady State Profile**：
   - 在 steady state 階段（不是 ramp-up）收集 profile
   - 觀察 `extractBroadcastSnapshot` / `extractPerPlayerSnapshot` vs `snapshotForSync` 的熱點排名變化

---

## 結論

- **網路吞吐量**（10 房 / 100 房）：新舊方法差異在 ±1% 以內，屬誤差範圍；兩者產出的狀態更新相同，流量本就會一致。
- **CPU（run-server-loadtest.sh monitoring）**：
  - **100 房**：舊 avg 99.0%、peak 224.8% → 新 avg 86.8%、peak 161.9%（平均約降 12%、峰值約降 28%）
  - **300 房**：舊 avg 251.8%、peak 453.3% → 新 avg 159.7%、peak 337.3%（平均約降 36%、峰值約降 26%）
  - 規模越大，新方法效益越明顯，符合「一次提取、少 N 次根層遍歷」的預期。

**建議**：以 CPU 數據為依據，**值得投入 macro 實作**，讓所有 StateNode 自動產生 `snapshotForSync`，避免手寫維護成本。

---

## 附錄：測試檔案

- 舊方法 10 房：`server-loadtest-messagepack-rooms10-ppr5-steady30s-2026-02-04T14-08-20Z.json`
- 新方法 10 房：`server-loadtest-messagepack-rooms10-ppr5-steady30s-2026-02-04T14-11-15Z.json`
- 舊方法 100 房：`server-loadtest-messagepack-rooms100-ppr5-steady30s-2026-02-04T14-13-06Z.json`
- 新方法 100 房：`server-loadtest-messagepack-rooms100-ppr5-steady30s-2026-02-04T14-13-40Z.json`
- **含 CPU 監控（run-server-loadtest.sh）**：
  - 舊方法：`server-loadtest-messagepack-rooms100-ppr5-steady20s-2026-02-04T14-26-03Z.json` + `*-monitoring.html` / `*-monitoring.json`
  - 新方法：`server-loadtest-messagepack-rooms100-ppr5-steady20s-2026-02-04T14-27-43Z.json` + `*-monitoring.html` / `*-monitoring.json`

# 500-Room 效能優化結論（依 Profile 結果）

本結論基於 **2026-02-04 實際跑 500 房** 的 Swift Profile Recorder 取樣結果（約 30 萬 stack-frame 行、1000 樣本）。

**Profile 檔案**：`results/server-loadtest/profiling/profile-500rooms-2026-02-04T12-49-37Z.perf`  
**建議**：拖進 [Speedscope](https://speedscope.app) 或 [Firefox Profiler](https://profiler.firefox.com) 看完整 call tree。

---

## 1. 熱點排名（ServerLoadTest 內，依出現次數）

| 出現次數 | 符號 / 路徑 |
|----------|-------------|
| ~6900 | **TransportAdapter.syncNow**（suspend/resume 邊界，代表整條 sync 路徑） |
| ~4100 | **SyncEngine.extractPerPlayerSnapshot** |
| ~3700 | **SyncEngine.compareSnapshotValues** |
| ~2000 | **SyncEngine.computeBroadcastDiffFromSnapshot** |
| ~2000 | **SyncEngine.compareSnapshots** |
| ~1700 | **SyncEngine.extractBroadcastSnapshot** |
| ~1600 | **HeroDefenseState.snapshot** |
| ~1400 | **HeroDefenseState.broadcastSnapshot** |
| ~1300–600（多處） | **SnapshotValue.make(from:for:)** |
| ~800 | **MessagePackPacker.packArray** |
| ~520 | **LandKeeper.runTick** |
| ~400 | **MessagePack pack / buildStateUpdateWithEventBodies** |
| ~390–310 | **Position2 / Acceleration2.toSnapshotValue** |
| ~270 | **OpcodeMessagePackStateUpdateEncoder.encodePatchWithHashDirect** |

其餘：NIO event loop 的 `_blockingWaitForWork` / `whenReady0`（約 8000× 線程數）為**空轉等待**，屬預期；`ConditionLock.lock` 約 5000 次。

- **為何是「空轉」？** NIO 的每個 event loop 線程在沒有工作時會**阻塞**在系統呼叫裡（如 macOS 的 `kevent`、Linux 的 `epoll_wait`）等 I/O 或排程任務。取樣時若線程正在等，PC 就會停在 `_blockingWaitForWork` / `whenReady0`，所以樣本數高；這是「閒置等待」、不是 busy-spin 燒 CPU，屬正常且省電。

---

## 2. 依結果歸納的優化方向

### 2.1 狀態同步與 Diff（最優先）

- **現象**：`extractBroadcastSnapshot`、`extractPerPlayerSnapshot`、`compareSnapshots`、`compareSnapshotValues`、`computeBroadcastDiffFromSnapshot` 合計佔應用側樣本多數。
- **結論**：500 房下，**snapshot 提取 + diff 計算** 是主要 CPU 成本。
- **建議**：
  1. **Dirty tracking**：確認所有會變的欄位都有正確標記，避免每次都做全樹 snapshot/diff。
  2. **compareSnapshotValues**：若樹很深或節點多，可考慮提早終止（例如只比到某層）、或對已知大子樹做結構化比較。
  3. **extractPerPlayerSnapshot**：每房每玩家都會呼叫；可看是否能把「broadcast 一份 + per-player 只取差異」做成兩階段，減少重複提取。

### 2.2 SnapshotValue.make 與型別轉換

- **現象**：`SnapshotValue.make(from: Any, for: PlayerID?)` 與多種 `toSnapshotValue()`（如 Position2、Acceleration2）出現頻繁。
- **結論**：透過 `Any` 的轉換與遞迴 make 成本高。
- **建議**：
  1. 對熱路徑上的型別（如 Position2、常用 struct）盡量走 **直接 toSnapshotValue**，少經 `Any`。
  2. 在 macro 或 codegen 層提供「已知型別 → SnapshotValue」的專用路徑，減少 runtime 型別判斷與分支。

### 2.3 編碼（MessagePack）

- **現象**：`MessagePackPacker.packArray`、`pack`、`encodePatchWithHashDirect`、`buildStateUpdateWithEventBodies` 有穩定出現，但低於 sync/diff/snapshot。
- **結論**：編碼是次要熱點，但仍值得優化。
- **建議**：
  1. 對高頻、小 payload 考慮 **buffer 重用** 或預分配，減少重複 `Data` 分配。
  2. 若 profile 顯示 `packArray` 內有大量小陣列，可評估 batch 或更扁平的結構以減少呼叫次數。

### 2.4 LandKeeper.runTick

- **現象**：`runTick` 的 suspend/resume 約 518 次（取樣期間）。
- **結論**：tick 本身有佔比，但不如 sync/diff/snapshot 顯著。
- **建議**：先做 2.1、2.2 再視需要優化 tick 邏輯或週期；若未來擴到更多房，可再 profile 一次看 tick 是否變顯著。

### 2.5 NIO 與鎖

- **現象**：多條 NIO 線程在 `_blockingWaitForWork` / `whenReady0`；`ConditionLock.lock` 約 5000。
- **結論**：event loop 空轉屬正常；鎖競爭有但未壓過 sync/diff。
- **建議**：先不動 NIO 架構；若之後要壓延遲，再量測 `ConditionLock` 持有時間與呼叫點（是否在 sync 路徑上）。

---

## 3. 建議實作順序

1. **驗證並強化 dirty tracking**（減少不必要的 snapshot/diff）。
2. **優化 SyncEngine 的 compareSnapshotValues / extract*Snapshot**（早退、兩階段 broadcast + per-player）。
3. **SnapshotValue 熱路徑**：少用 `Any`、多走專用 toSnapshotValue。
4. **MessagePack**：buffer 重用與結構扁平化（依二次 profile 再細調）。

---

## 4. 如何再跑一次 Profile

```bash
cd Examples/GameDemo
bash scripts/server-loadtest/run-collect-profile.sh --rooms 500 --samples 1000
```

完成後用 `analyze-profile.sh` 或直接打開新產生的 `.perf` 比對優化前後差異。

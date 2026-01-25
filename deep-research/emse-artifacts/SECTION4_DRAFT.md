[English version TBD]

## 第 4 章 — 實證評估（EMSE 草稿，中文版）

本章以軟體工程實證研究常用的「黃金鐵三角」為主軸，將評估拆成三個研究問題（RQ）：**效率（Efficiency）**、**擴展性（Scalability）**、**正確性/能力（Correctness & Capabilities）**。

### 4.1 實驗設定（Experimental Setup）

- **受評系統**：SwiftStateTree（SST），使用 `hero-defense` land 作為測試案例。
- **工作負載（Workload）**：
  - 每次 iteration（每個 room）先執行 `stepTickOnce()` × `ticksPerSync`，再執行一次 `syncNow()`。
  - 本章主要設定：`ticksPerSync = 2`（tick=20Hz、sync=10Hz），`playersPerRoom = 5`。
- **硬體/作業系統（Hardware/OS）**：
  - Benchmark 的硬體資訊以結果檔的 JSON envelope 為準（`metadata.environment.*`）。
  - 決定性驗證（RQ3）採用跨架構：**Apple M2/macOS（arm64）錄製** → **Linux/x86_64 重播驗證**。
- **比較的編碼格式（RQ1/RQ2）**：
  - Baseline：`JSON Object`
  - Optimized：`Opcode MsgPack (PathHash)`

---

### 4.2 RQ1 — 網路效率（Network Efficiency）：opcode-driven 編碼能節省多少 payload？

**敘事方式（從演進史建立因果鏈）**  
為了避免把 RQ1 寫成「單純跑分」，本節以 SST 的傳輸協議演進順序敘述，將設計決策與效益連結起來（詳見 `docs/transport_evolution.md` / `docs/transport_evolution.zh-TW.md`）：

1. **Baseline：JSON Object**  
   - 優點：可讀性高、易除錯  
   - 缺點：同步封包大（payload bytes 高）
2. **中間階段：Opcode-driven（概念層）**  
   - 核心想法：將「狀態變更」表達成 opcode array，讓 payload 更接近差分/指令流（減少結構與欄位名稱帶來的膨脹）  
   - PathHash 的目的：用 hash 取代長路徑字串，進一步壓縮
3. **最終版：Opcode MsgPack + PathHash**  
   - 用二進位編碼（MessagePack）承載 opcode array，並搭配 PathHash 壓縮路徑  
   - 目標：同時降低 payload size，並降低編碼/解碼與傳輸成本

**指標（Metric）**  
以 `CountingTransport` 量測每次 sync 的 application payload 大小：`bytesPerSync`。此指標明確代表 **應用層 payload bytes**，不包含 WebSocket framing/TLS/傳輸層壓縮等額外開銷。

**資料來源（Evidence）**  
- 演進敘事：`docs/transport_evolution.md`、`docs/transport_evolution.zh-TW.md`
- 可重現的 benchmark 原始結果檔：
  - `Examples/GameDemo/Sources/EncodingBenchmark/results/scalability-matrix-json-object-ppr5-200iterations-tick2-2026-01-25T06-12-16Z.json`
  - `Examples/GameDemo/Sources/EncodingBenchmark/results/scalability-matrix-messagepack-pathhash-ppr5-200iterations-tick2-2026-01-25T06-12-37Z.json`

**圖（直接嵌入）**  
以下圖表顯示 `rooms=50`、parallel 模式下的 `bytesPerSync` 對比（application payload）：

![RQ1 Bytes per sync at 50 rooms (parallel)](/deep-research/emse-artifacts/artifacts/rq1_bytes_per_sync_rooms50_parallel.svg)

**表（直接嵌入）**  
（取自 `deep-research/emse-artifacts/artifacts/rq1_network_efficiency.csv`）

| Format                    | Rooms | playersPerRoom | ticksPerSync | iterations | serial bytesPerSync | parallel bytesPerSync |
|--------------------------|------:|---------------:|-------------:|-----------:|--------------------:|----------------------:|
| JSON Object              | 10    | 5              | 2            | 200        | 18183               | 17656                 |
| JSON Object              | 30    | 5              | 2            | 200        | 58397               | 53978                 |
| JSON Object              | 50    | 5              | 2            | 200        | 110387              | 91400                 |
| Opcode MsgPack (PathHash)| 10    | 5              | 2            | 200        | 4776                | 4678                  |
| Opcode MsgPack (PathHash)| 30    | 5              | 2            | 200        | 14933               | 14013                 |
| Opcode MsgPack (PathHash)| 50    | 5              | 2            | 200        | 27413               | 23475                 |

**最終版總結（Final vs Baseline，rooms=50）**  
為了讓讀者快速理解「最終版帶來的工程含義」，下表以 `rooms=50`、parallel 模式匯總 **Size + Compute** 的直覺對比（CPU 的完整推論與容量模型在 RQ2 展開）：  

| 指標（rooms=50, parallel） | JSON Object | Opcode MsgPack (PathHash) | 改善幅度 |
|----------------------------|-----------:|---------------------------:|--------:|
| bytesPerSync               | 91400      | 23475                      | -74.3%  |
| avgCostPerSyncMs           | 0.0801     | 0.0646                     | -19.4%  |

**關鍵結論（可直接用在論文的句型）**  
在相同遊戲工作負載下，`Opcode MsgPack (PathHash)` 相較 `JSON Object` 在各房間規模下都能顯著降低 `bytesPerSync`，代表 SST 的 opcode-driven 編碼在頻寬成本上具有實質工程效益。

---

### 4.3 RQ2 — 伺服器容量模型（Server Capacity Modeling）：room-level parallelism 能帶來多少營運能力提升？

**目的（Goal）**  
將 micro-level 的計算成本（每房間每次 sync 的平均成本）推導成 macro-level 的「可承載房間/人數」估算，使結果對開發者/營運更有意義。

**量測值（Measurements）**  
使用 benchmark 輸出的 `avgCostPerSyncMs`（per-room、per-sync），並同時取 **serial** 與 **parallel**。

**模型（Model）**  
在 `ticksPerSync=2` 的設定下，tick 的成本已包含在每次 sync 的平均成本裡，因此容量模型可寫成：

- `syncHz = 10`
- `costRoomMsPerSecond = avgCostPerSyncMs * syncHz`
- `cpuBudgetMsPerSecond = cpuLogicalCores * 1000 * cpuUsageLimit`
- `MaxRooms ≈ cpuBudgetMsPerSecond / costRoomMsPerSecond`
- `MaxPlayers ≈ MaxRooms * playersPerRoom`

本章採用 `cpuUsageLimit = 0.7`，保留 headroom 給遊戲邏輯、網路與 runtime overhead。

**表（直接嵌入）**  
（取自 `deep-research/emse-artifacts/artifacts/rq2_capacity_model.md`）

| format                    | rooms | avgCostPerSyncMs(serial) | avgCostPerSyncMs(parallel) | MaxRooms(serial) | MaxRooms(parallel) | MaxPlayers(serial) | MaxPlayers(parallel) |
| ------------------------- | ----- | ------------------------ | -------------------------- | ---------------- | ------------------ | ------------------ | -------------------- |
| JSON Object               | 10    | 0.3385                   | 0.0776                     | 2481.4           | 10824.5            | 12407              | 54122                |
| JSON Object               | 30    | 0.3483                   | 0.0701                     | 2411.9           | 11975.9            | 12060              | 59880                |
| JSON Object               | 50    | 0.3834                   | 0.0801                     | 2191.2           | 10490.8            | 10956              | 52454                |
| Opcode MsgPack (PathHash) | 10    | 0.2977                   | 0.1047                     | 2821.3           | 8020.6             | 14106              | 40103                |
| Opcode MsgPack (PathHash) | 30    | 0.3199                   | 0.0632                     | 2626.0           | 13295.3            | 13130              | 66477                |
| Opcode MsgPack (PathHash) | 50    | 0.3404                   | 0.0646                     | 2467.7           | 13009.3            | 12338              | 65046                |

**重要說明（避免審稿人誤解）**  
上表是「計算側」的容量估算：代表 tick+sync+encoding 的 CPU 近似上限；實際系統仍會受到網路、IO、其他遊戲邏輯、排程與 GC/allocator 影響，因此建議將此結果解讀為 **room-level parallelism 的可量化營運含義**，而不是完整 end-to-end 的壓測結論。

---

### 4.4 RQ3 — 決定性驗證（Determinism Verification）：跨架構重播是否能達到 0 mismatches？

**目標（Goal）**  
驗證 SST 的 Deterministic Re-evaluation：將 live 錄製的 inputs + resolver outputs 固定化，於不同 CPU 架構上重播並逐 tick 比對 state hash。

**資料集（Datasets）**  
- 含互動輸入（262 ticks；含 actions/client events）：
  - `Examples/GameDemo/reevaluation-records/hero-defense-2026-01-25T05-17-26Z-CD3C81D9.json`
  - `Examples/GameDemo/reevaluation-records/hero-defense-2026-01-25T05-17-35Z-C9517718.json`
- 多 seed 重複（120 ticks；join + tick 演進）：
  - `...F7E0C6B2.json`, `...7FD0D4DC.json`, `...0B596849.json`

**程序（Procedure）**  
1. Live mode 錄製並啟用 per-tick `stateHash`。
2. Reevaluation mode 重播，跳過 resolver 執行並使用錄製的 `resolverOutputs`。
3. 逐 tick 比對「計算出的 state hash」與「錄製的 ground truth」。
4. 同一台機器連跑兩次 re-evaluation，驗證 run1 vs run2 的一致性。

**實作工具（現成）**  
使用 `ReevaluationRunner`：
```bash
swift run -c release ReevaluationRunner --input <record.json> --verify
```

**結果摘要（本次驗證）**  
- 5 份 record 全部驗證通過：
  - ✅ Verified: computed hashes match recorded ground truth
  - ✅ Cross-architecture verification: arm64 → x86_64
  - ✅ Verified: hashes are identical across two re-evaluation runs
- 互動版（262 ticks）統計：Actions=6、Client Events=4、Lifecycle Events=2。
- 多 seed 版（120 ticks）統計：Actions=0、Client Events=0、Lifecycle Events=2。

---

### 4.5 有效性威脅（Threats to Validity）

- **建構有效性（Construct validity）**：
  - `bytesPerSync` 是 application payload bytes，不含 framing/TLS/傳輸層壓縮。
  - 容量模型以 `cpuUsageLimit` 抽象化非 sync 的成本（IO、遊戲邏輯、排程等）。
- **內部有效性（Internal validity）**：
  - benchmark 可能受系統雜訊影響；可補多次重跑並報 median/IQR。
- **外部有效性（External validity）**：
  - 工作負載目前以 `hero-defense` 為主；可擴展到更多 land/scenario。
  - 120-tick records 偏簡；以 262-tick（含互動輸入）作為主要 determinism 證據更強。

---

### 4.6 小結（Summary）

- **RQ1（效率）**：opcode-driven（MsgPack+PathHash）在相同工作負載下顯著降低 `bytesPerSync`。
- **RQ2（擴展性）**：room-level parallelism 可量化地提升「估算承載 rooms/players」。
- **RQ3（正確性/能力）**：跨架構 re-evaluation 達成 0 mismatches（本次驗證五份 record 全數通過）。


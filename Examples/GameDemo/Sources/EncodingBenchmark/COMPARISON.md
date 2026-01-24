# 序列 vs 並行：Room 處理方式對比

> **測試數據來源**：實際 benchmark 測試（1000 iterations，包含 tick 模擬，JSON Object，5 players per room）  
> **測試文件**：`results/scalability-test-json-object-1000iterations-tick-2026-01-24T16-12-01Z.json`  
> **並行效率**：使用標準定義 $E = S/P$，其中 $S = T_s/T_p$，$P=\min(\text{rooms}, \text{CPU cores})$。（備援：`E = S / P`, `S = T_s / T_p`, `P = min(rooms, CPU cores)`）  
> **計算流程（Algorithm）**：  
> - **量測輸入**：對每個 `rooms`，在「完全相同的 workload」下各跑一次  
>   - **Serial**：單執行緒/單迴圈依序處理所有 rooms，得到總時間 $T_s$（ms）  
>   - **Parallel**：rooms 以 task group 併行處理（room-level parallelism），得到總時間 $T_p$（ms）  
> - **Speedup**：$S = T_s/T_p$（同一個 `rooms`、同一個工作量下的時間比）  
> - **Theoretical parallelism**：$P=\min(\text{rooms}, \text{CPU cores})$  
>   - **原因**：同一時間最多只能同時跑 `CPU cores` 個「有效並行單位」，rooms 多於核心時並行度會被核心數上限截斷  
> - **Parallel efficiency**：$E = S/P$（常以百分比呈現：$E \times 100\%$）  
> - **Throughput（sync/s）**：$\text{throughput}=\text{syncCount}/(\text{timeSeconds})$，其中 `syncCount = rooms × iterations`（本表的 throughput 分別用 serial 與 parallel 的總時間計算）

---

## 架構想解決的問題

多人、多人房間的伺服器常見瓶頸是「單一迴圈依序處理所有房間」：

- **Latency**：房間數越多，一輪處理越久（線性增長）。
- **CPU 利用率**：多核 CPU 下，若房間仍序列處理，會浪費核心。

SwiftStateTree 的核心賣點是：**每個房間（LandKeeper）天然可並行**，讓「room-level parallelism」變成預設能力，而不是後補的手工並行。

---

## 核心設計概念（為何能做 Room-based parallel）

- **Actor per room（LandKeeper 是 actor）**  
  - 每個房間獨立序列化自己的狀態變更（thread-safe）。
  - 不同房間彼此隔離，天然可並行。

- **狀態樹 + Snapshot / Diff Sync**  
  - Sync 不需要「鎖住整個世界」，而是以 snapshot/diff 結構化產出更新。

- **Action（同步）與 Resolver（非同步）分離**  
  - 讓 state mutation 維持同步/原子性，避免長 await 卡住 actor。  
  - 詳細說明請看 `ACTOR_BLOCKING.md`（本文件不重複展開）。

---

## 兩種實作方式對比（程式碼形狀）

### 傳統序列方式（單個 process / loop）

```swift
// Traditional: process rooms sequentially
for room in rooms {
    room.update() // tick
    room.sync()   // broadcast state
}
```

- **優點**：簡單
- **缺點**：房間數增加會線性拖慢；多核利用率差

### SwiftStateTree（每房間 actor，房間可並行）

```swift
// SwiftStateTree: each room has its own actor (LandKeeper)
// Rooms can be processed concurrently (room-level parallelism)
await withTaskGroup(of: Void.self) { group in
    for room in rooms {
        group.addTask {
            await room.keeper.stepTickOnce()
            await room.adapter.syncNow()
        }
    }
}
```

---

## Benchmark 方法與測試環境

### 工作負載（Benchmark 的「一輪」做什麼）

- 每次 iteration：
  - 每個房間先 `stepTickOnce()`（模擬遊戲 tick）
  - 再 `syncNow()`（模擬同步狀態）
- 測試 room counts：$1, 2, 4, 8, 16, 32, 50$
- iterations：1000
- encoding：JSON Object（避免把重點混到不同 encoding）
- build：Release（`-c release`）

### 測試硬體（要跟數據放一起）

| 項目 | 規格 |
|------|------|
| **CPU** | AMD Ryzen 5 7600X 6-Core Processor |
| **CPU 核心數** | 10 個邏輯核心（5 個物理核心 × 2 threads） |
| **架構** | x86_64 |
| **記憶體** | 15.8 GB |
| **作業系統** | Linux (WSL2) |

備註：WSL2 可能帶來額外調度/IO 開銷，結果用於「趨勢與差距」展示很合適，但不同環境的絕對值會不同。

---

## Benchmark 結果（Room scalability）

欄位定義：
- **Speedup**：序列時間 ÷ 並行時間  
- **Parallel throughput**：`parallel.throughputSyncsPerSecond`（表格內吞吐量都指並行）  
- **Parallel efficiency**：$E = S/P$，$P=\min(\text{rooms}, \text{CPU cores})$  
- **Time saved**：$1 - T_p/T_s$

| Rooms | Serial (ms) | Parallel (ms) | Speedup | Serial throughput (sync/s) | Parallel throughput (sync/s) | Efficiency | Time saved |
|------:|------------:|--------------:|--------:|----------------------------:|------------------------------:|----------:|----------:|
| 2     | 673.71      | 437.39        | 1.54x   | 2,968.6                     | 4,572.6                       | 77.0%     | 35.1%     |
| 4     | 1,393.50    | 490.03        | 2.84x   | 2,870.5                     | 8,162.7                       | 71.1%     | 64.8%     |
| 8     | 2,791.72    | 729.31        | 3.83x   | 2,865.6                     | 10,969.2                      | 47.8%     | 73.9%     |
| 16    | 5,728.87    | 1,356.27      | 4.22x   | 2,792.9                     | 11,797.1                      | 42.2%     | 76.3%     |
| 32    | 12,179.19   | 2,913.64      | 4.18x   | 2,627.4                     | 10,982.8                      | 41.8%     | 76.1%     |
| 50    | 21,100.21   | 4,538.99      | 4.65x   | 2,369.6                     | 11,015.7                      | 46.5%     | 78.5%     |

### 重點解讀（用於差異化說明）

- **50 rooms**：並行 4.65x（21.1s → 4.54s），節省 78.5% 時間。
- **吞吐量**：並行吞吐量約落在 11k sync/s；序列吞吐量約 2.3–2.9k sync/s。
- **註記（Rooms=1）**：單房間基本上不存在「room-level 並行」，此時 speedup/efficiency 主要反映測量雜訊、cache、turbo、排程波動等造成的 $T_p < T_s$。  
  - 若要更嚴謹，可加 warmup、多次取平均/中位數（本文件先以單次結果呈現趨勢）。

---

## 實作難度：不靠統一架構要做 Room parallel 有多麻煩？

傳統做法要自己解決：
- thread-safety（鎖、死鎖、競態）
- room lifecycle / error handling / cancellation
- 控制並行度（避免過度排程/資源競爭）

SwiftStateTree 把上述成本壓在框架裡（actor 隔離 + 統一狀態樹 + 同步 action + resolver 分離），讓 room-level parallelism 成為可控且可維護的預設行為。

---

## 延伸閱讀（詳細架構/阻塞分析）

- `ACTOR_BLOCKING.md`：Action 若 async 為何會阻塞 tick/sync？Resolver 分離如何避免？

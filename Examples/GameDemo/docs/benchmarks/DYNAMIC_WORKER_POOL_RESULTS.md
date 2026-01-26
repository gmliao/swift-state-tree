# Dynamic Worker Pool（真正的 Task Reuse）實驗結果

## 實驗背景

之前的 "Worker Pool" 實驗**並非真正的 Worker Pool**：
- 每個 iteration 都創建新的 tasks（100 iterations × 24 workers = 2,400 tasks）
- 沒有 task reuse
- 靜態分配房間，無動態負載均衡

本實驗實現**真正的 Worker Pool**：
- 只創建 **12 個長期存活的 worker tasks**
- Workers 從共享 `WorkQueue` (actor) 不斷取出工作
- 動態負載均衡：快的 worker 自動處理更多工作

## 核心實現

### WorkQueue (Actor-based Thread-Safe Queue)

```swift
actor WorkQueue {
    private var items: [(iteration: Int, roomIndex: Int)] = []
    
    func enqueue(_ newItems: [(Int, Int)]) {
        items.append(contentsOf: newItems)
    }
    
    func dequeue() -> (Int, Int)? {
        guard !items.isEmpty else { return nil }
        return items.removeFirst()
    }
}
```

### Dynamic Worker Pool 執行

```swift
// 準備所有工作項（100 iterations × 100 rooms = 10,000 個工作）
let workItems = (0..<iterations).flatMap { iter in
    (0..<rooms.count).map { roomIdx in (iter, roomIdx) }
}
let workQueue = WorkQueue()
await workQueue.enqueue(workItems)

// 只創建 12 個 workers（固定數量）
await withTaskGroup(of: Void.self) { group in
    for workerID in 0..<12 {  // 只執行一次！
        group.addTask {
            // Worker 循環：不斷取工作直到隊列為空
            while let (iteration, roomIdx) = await workQueue.dequeue() {
                let room = rooms[roomIdx]
                // ... 處理房間的 tick & sync ...
            }
        }
    }
}
```

## 實驗結果

### 三種策略對比

| Rooms | Strategy               | Time (ms) | Tasks Created | Throughput (syncs/s) | Speedup | Winner |
|-------|------------------------|----------:|--------------:|---------------------:|--------:|--------|
| 50    | **Current (Unlimited)**| 298.97    | 5,000         | 16,724.3             | 1.00x   | ❌     |
| 50    | Static Pool            | 324.15    | 2,400         | 15,425.0             | 0.92x   | ❌     |
| 50    | **Dynamic Pool**       | **252.35**| **12**        | **19,813.6**         | **1.18x** | ✅ |
|       |                        |           |               |                      |         |        |
| 100   | **Current (Unlimited)**| 502.66    | 10,000        | 19,894.3             | 1.00x   | ❌     |
| 100   | Static Pool            | 562.51    | 2,400         | 17,777.4             | 0.89x   | ❌     |
| 100   | **Dynamic Pool**       | **494.41**| **12**        | **20,226.3**         | **1.02x** | ✅ |
|       |                        |           |               |                      |         |        |
| 200   | **Current (Unlimited)**| **1,001.08** | 20,000     | **19,978.4**         | **1.00x** | ✅ |
| 200   | Static Pool            | 1,125.10  | 2,400         | 17,776.1             | 0.89x   | ❌     |
| 200   | Dynamic Pool           | 1,107.55  | **12**        | 18,057.9             | 0.90x   | ❌     |

### 關鍵發現

#### 🎯 **Dynamic Pool 在小規模（50-100 rooms）下勝出！**

- **50 rooms**：Dynamic Pool 比 Current **快 18%**
- **100 rooms**：Dynamic Pool 比 Current **快 2%**
- **200 rooms**：Current 比 Dynamic Pool **快 10%**

#### 📊 Task 創建數量對比

```
50 rooms:
Current:        ████████████████████ 5,000 tasks
Static Pool:    ██████████ 2,400 tasks      (-52%)
Dynamic Pool:   █ 12 tasks                   (-99.8%) ⭐

100 rooms:
Current:        ████████████████████████████████████████ 10,000 tasks
Static Pool:    ██████████ 2,400 tasks                              (-76%)
Dynamic Pool:   █ 12 tasks                                           (-99.9%) ⭐

200 rooms:
Current:        ████████████████████████████████████████████████████████████████████████████████ 20,000 tasks
Static Pool:    ██████████ 2,400 tasks                                                                      (-88%)
Dynamic Pool:   █ 12 tasks                                                                                   (-99.9%) ⭐
```

#### 🔬 效能分析

**為什麼 Dynamic Pool 在小規模下更快？**

1. **Task 創建開銷顯著**
   - 50 rooms：5,000 tasks → 12 tasks，效能提升 **18%**
   - 證明 Swift Runtime 的 task 創建/調度仍有成本

2. **動態負載均衡優勢**
   - Workers 自動處理不同負載的房間
   - 快的 worker 處理更多工作（從結果看，worker 處理量從 390-434 不等）
   - 避免靜態分配的負載不均問題

3. **減少 TaskGroup 創建/銷毀**
   - Current：100 個 TaskGroup（每 iteration 一個）
   - Dynamic Pool：1 個 TaskGroup（整個測試期間）

**為什麼 Dynamic Pool 在大規模（200 rooms）下變慢？**

1. **Actor Queue Contention**
   - 200 rooms × 100 iterations = 20,000 次 `workQueue.dequeue()` 調用
   - 每次調用都需要獲取 actor lock
   - 12 個 workers 競爭同一個 actor queue，成為瓶頸

2. **失去全並行優勢**
   - Current：所有 200 個房間同時開始處理
   - Dynamic Pool：workers 順序處理，最多同時處理 12 個房間

3. **Cache Locality 損失**
   - Workers 在不同 iteration 處理同一房間，cache 友善度降低
   - Current：每個 task 專注處理一個房間的一次 sync，cache 命中率高

## 結論

### ✅ 何時使用 Dynamic Worker Pool

**推薦使用於**：
- **小到中等規模**（< 100 rooms）
- **需要動態負載均衡** 的場景
- **Task 創建成本敏感** 的環境
- **長期運行** 的伺服器（減少 GC 壓力）

**優勢**：
- Task 創建數量減少 **99.8%**
- 動態負載均衡自動適應不同房間負載
- 記憶體使用更穩定（固定數量的 tasks）

### ✅ 何時使用 Current (Unlimited Parallelism)

**推薦使用於**：
- **大規模**（> 100 rooms）
- **CPU 核心數遠小於房間數** 的場景
- **需要極致吞吐量**

**優勢**：
- 所有房間全並行處理，吞吐量最高
- 無 actor queue contention
- Cache locality 更好

### 🎯 最終建議：混合策略

```swift
let effectiveWorkerCount: Int
if rooms.count <= 100 {
    // 小規模：使用 Dynamic Worker Pool
    effectiveWorkerCount = ProcessInfo.processInfo.activeProcessorCount
    return await runMultiRoomBenchmarkWithDynamicWorkerPool(...)
} else {
    // 大規模：使用 Unlimited Parallelism
    return await runMultiRoomBenchmark(parallel: true, ...)
}
```

## 進一步優化方向

### 1. Batch Dequeue 減少 Actor Contention

```swift
actor WorkQueue {
    func dequeueBatch(count: Int) -> [(Int, Int)] {
        let batchSize = min(count, items.count)
        let batch = Array(items.prefix(batchSize))
        items.removeFirst(batchSize)
        return batch
    }
}

// Worker 使用 batch dequeue
while true {
    let batch = await workQueue.dequeueBatch(count: 10)
    guard !batch.isEmpty else { break }
    for (iteration, roomIdx) in batch {
        // ... 處理工作 ...
    }
}
```

預期效果：減少 actor lock 競爭，提升大規模效能。

### 2. Lock-Free Work Stealing Queue

使用 atomic operations 實現無鎖工作竊取隊列，避免 actor lock overhead。

### 3. Hybrid Approach: Batch + Dynamic Pool

- 每個 worker 處理一批房間（例如 10 個）
- Workers 從 queue 取批次而非單個工作
- 平衡 actor contention 和負載均衡

## 資料來源

測試結果 JSON 檔案：
- [50 rooms](../results/encoding-benchmark/worker-pool-comparison-v2-rooms50-ppr5-iter100-tick2-2026-01-26T13-00-46Z.json)
- [100 rooms](../results/encoding-benchmark/worker-pool-comparison-v2-rooms100-ppr5-iter100-tick2-2026-01-26T13-00-48Z.json)
- [200 rooms](../results/encoding-benchmark/worker-pool-comparison-v2-rooms200-ppr5-iter100-tick2-2026-01-26T13-00-52Z.json)

## 測試環境

- **CPU**: AMD Ryzen 5 7600X (6 physical cores, 12 logical)
- **Workers**: 12 (Dynamic Pool), 24 (Static Pool)
- **Build**: Release mode
- **Swift Version**: 6.2.3
- **OS**: Linux (WSL2)

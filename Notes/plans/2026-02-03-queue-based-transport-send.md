# Queue-based WebSocketTransport Send Path

**狀態**：✅ 已實作（2026-02-03）

## 目前版本（P1 Queue-based，已實作）

**WebSocketTransport**（`Sources/SwiftStateTreeTransport/WebSocketTransport.swift`）：

- **型態**：`actor`，單一 instance 管理所有 session
- **Send 路徑**：`send(Data, EventTarget)`、`sendBatch([(Data, EventTarget)])` 皆需 `await`（actor hop）
- **內部**：`sessionQueues: [SessionID: SessionSendQueue]`，每 session 一個 `AsyncStream` + drain task
- **P0 優化**：已實作 `sendBatch`，每 room 每 tick 一次 batch，將 actor 呼叫從 ~10,000/s 降為 ~5,000/s
- **實測**：500-room rttP95 約 736–802 ms（最佳 run），部分 run 變異大（2908–4074 ms）

**TransportAdapter**：呼叫 `await transport.sendBatch(batch)`，每次 sync 一次 await。

### 版本對照

| 項目 | 目前（P0） | 計畫（Queue-based） |
|------|------------|---------------------|
| Send 入口 | `await transport.sendBatch()` | `transport.sendQueue?.enqueueBatch()`（無 await） |
| Producer 阻塞 | 每次 batch 一次 actor hop | 無，僅 lock + append |
| Buffer | 無（直接進 actor） | SendQueue 暫存，drain 批次取出 |
| Buffer 回收 | - | drain 後 capacity reuse |

## 背景

POC (`ws-loadtest/poc/`) 驗證：500 producers 競爭單一 actor 時，Queue 比 Actor 快約 31x（p95 延遲）、2.3x（吞吐）。

目前 WebSocketTransport 為 actor，每次 `await transport.send()` 都是 actor hop，造成 producer 排隊。

## 目標

將 send 路徑改為 queue-based，讓 producer 端無需 await，消除 actor 競爭。

## 設計

### 架構

```
TransportAdapter                    WebSocketTransport (actor)
      │                                      │
      │  enqueue(data, target)               │
      ├──────────────────────────────────────► SendQueue (lock-based, non-actor)
      │         (no await)                    │
      │                                       │  drain task: dequeue batch
      │                                       │  → dispatchBatch() [actor]
      │                                       ▼
      │                              sessionQueues → per-session AsyncStream
```

### 元件

1. **SendQueue**：thread-safe queue，`enqueue(Data, EventTarget)` 無需 await
2. **WebSocketTransport**：保留 actor，新增 drain task 從 SendQueue 取 batch 後呼叫 `dispatchBatch`
3. **Transport 協定**：新增 optional `sendQueue: TransportSendQueue?`，有則用 enqueue，否則 fallback 到 `await send()`

### 介面

```swift
public protocol TransportSendQueue: Sendable {
    func enqueue(_ message: Data, to target: EventTarget)
    func enqueueBatch(_ updates: [(Data, EventTarget)])
}

// WebSocketTransport 提供
public nonisolated var sendQueue: TransportSendQueue? { get }
```

### 實作要點

- SendQueue 內部用 NSLock + [Item]，或 Deque
- Drain 每 16–64 筆或每 0.2ms（預設）觸發一次 dispatch；可透過 `WebSocketTransport(drainIntervalMs:)` 調整
- Connection/disconnection 仍在 actor 內處理
- sessionQueues 僅由 drain（在 actor 內）存取

### Queue Buffer 與回收

| 機制 | 說明 | 實作 |
|------|------|------|
| **Drain 清空** | 取出一批後清空 queue，避免無限成長 | ✅ 取 batch 後 swap 或 `removeAll` |
| **Capacity reuse** | 保留 array 容量，減少重複分配 | 取 batch 時 `swap(&buffer, &batch)`，drain 後可將空 array 回填或 `removeAll(keepingCapacity: true)` |
| **Backpressure** | 上限長度，滿時 drop 或回傳 | 可選：`maxQueueSize`，超過時 drop 最舊或回傳錯誤 |
| **Object pool** | 重用 Data/ByteBuffer | 暫不實作，依 profile 再評估 |

**目前計畫**：先做 drain 清空 + capacity reuse；backpressure 視負載測試再決定是否加入。

## 實作步驟（已完成）

1. ✅ 新增 `TransportSendQueue` protocol（Transport.swift）與 `WebSocketTransportSendQueue`（WebSocketTransport.swift）
2. ✅ WebSocketTransport init 時建立 SendQueue，啟動 drain task（nonisolated(unsafe) 以通過 actor init）
3. ✅ WebSocketTransport 提供 `transportSendQueue`（nonisolated）供外部取得
4. ✅ TransportAdapter 新增 `transportSendQueue` 參數，優先使用 `enqueueBatch()`，否則 fallback `await sendBatch()`
5. ✅ LandManager 建立 adapter 時傳入 `transport.transportSendQueue`
6. ✅ E2E 測試通過；swift test 702 項通過

## 風險

- 需確保 connection/disconnection 與 drain 的執行順序
- 若 drain 過慢，queue 可能堆積（可加 backpressure 緩解）

## 成功指標

- E2E 測試通過
- 500-room rttP95 較 P0 基準（736 ms）有明顯改善

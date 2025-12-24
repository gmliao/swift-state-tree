# 概觀

SwiftStateTree 是以「單一權威 StateTree + 同步規則 + Land DSL」為核心的伺服器邏輯引擎。
核心關注點是：把狀態變更集中在伺服器、透過同步規則把必要資料發送給客戶端。

## 模組組成

- `SwiftStateTree`：核心型別、Sync、Land DSL、Runtime、Schema 生成
- `SwiftStateTreeTransport`：Transport 抽象、WebSocketTransport、Land 管理
- `SwiftStateTreeHummingbird`：Hummingbird Hosting、JWT/Guest、Admin Routes
- `SwiftStateTreeMatchmaking`：Matchmaking 與 Lobby 支援
- `SwiftStateTreeMacros`：`@StateNodeBuilder`/`@Payload`/`@SnapshotConvertible`
- `SwiftStateTreeBenchmarks`：基準測試執行檔

## 系統資料流（高層）

```
Client
  ↕ WebSocket
WebSocketTransport
  ↕ TransportAdapter
LandKeeper (Runtime)
  ↕ SyncEngine / StateSnapshot
StateNode (StateTree)
```

## 核心概念

- StateNode：伺服器權威狀態，使用 `@StateNodeBuilder` 產生必要 metadata
- SyncPolicy：定義欄位同步策略（broadcast/per-player/masked/custom）
- Land：邏輯單位（規則、生命周期、事件處理）
- LandKeeper：執行器（處理 join/leave、action/event、tick、sync）
- TransportAdapter：把 transport message 轉成 LandKeeper 呼叫

## 文件入口

- `docs/quickstart.md`
- `docs/core/README.md`
- `docs/transport/README.md`
- `docs/hummingbird/README.md`

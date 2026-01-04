# Transport

Transport 層將網路連線與 LandKeeper 串接，核心目標是「不把網路細節暴露給 Land DSL」。

## 設計重點

- Land 層只關心 `LandContext` 與 handlers，不知道 WebSocket/HTTP 細節
- Transport 層負責連線管理、訊息序列化與路由
- 同步採 snapshot + diff，避免阻塞 state mutation

## 資料流

```
Client ↔ WebSocketTransport ↔ TransportAdapter ↔ LandKeeper
```

## 三層識別

- `playerID`：帳號/玩家身分（業務層）
- `clientID`：裝置或 client instance（應用端提供）
- `sessionID`：連線層識別（server 產生）

這三層識別會進入 `LandContext`，讓 handler 有一致的使用介面，
也支援多裝置、多連線的行為控制。

## 核心組件

- Transport protocol：抽象連線行為（start/stop/send）
- WebSocketTransport：預設 WebSocket 實作
- TransportAdapter：解析訊息並呼叫 LandKeeper
- LandManager / Registry：管理多房間
- LandRouter / LandRealm：跨房間路由與控制

## Join 與 Session 流程

- client 必須明確送出 join request
- join 會建立 `PlayerSession`，並依序執行 `CanJoin` / `OnJoin`
- 初次加入會回傳 snapshot，後續由 `StateUpdate`（firstSync/diff）接續

PlayerSession 欄位優先序：

1. join request 內容
2. JWT payload
3. guest session

## 同步模型

- snapshot：完整狀態（含 per-player 過濾）
- diff：只傳變更（path-based patches）
- firstSync：玩家首次建立 cache 後送出一次

## 錯誤處理

- join/action/event 錯誤會回傳 `ErrorPayload`
- join 會檢查 landID 與 session 狀態，避免重複加入或錯誤路由

## 多房間支援

- `LandManager` 管理 Land lifecycle 與查詢
- `LandRouter` 負責將連線導向對應 land
- multi-room 模式下 join 會依 landType + instanceId 進行路由

## 並行編碼（Parallel Encoding）

`TransportAdapter` 支援並行編碼狀態更新，以提升多玩家場景下的效能。

### 基本模式

當啟用並行編碼時，多個玩家的狀態更新會使用 `TaskGroup` 並行編碼：

```swift
let adapter = TransportAdapter(
    keeper: keeper,
    transport: transport,
    landID: landID,
    enableParallelEncoding: true
)
```

### 並行編碼行為

並行編碼會根據玩家數量和房間配置自動調整並行度：

**啟用條件**：
- 玩家數 >= `minPlayerCount`（預設 20）
- 使用 JSON codec（thread-safe）

**並行度計算**：
```swift
concurrency = min(perRoomCap, batchWorkers, pendingUpdateCount)
```

其中：
- **`perRoomCap`**：每房間並行度上限
  - 玩家數 < 30：`lowCap = 2`
  - 玩家數 >= 30：`highCap = 4`
- **`batchWorkers`**：根據批次大小計算
  - `batchWorkers = ceil(玩家數 / batchSize)`
  - `batchSize = 12`（預設）
- **`pendingUpdateCount`**：待處理的更新數量

**注意**：並行度由 `perRoomCap` 和 `batchWorkers` 決定，通常遠小於 CPU 核心數，所以實際並行度不會超過系統能力。Swift 的 `TaskGroup` 會自動管理任務排隊，即使創建大量任務，系統也只會同時運行約等於 CPU 核心數的任務。

**範例**：
- 30 個玩家：`perRoomCap=4`, `batchWorkers=3` → `concurrency=3`（受 `batchWorkers` 限制）
- 50 個玩家：`perRoomCap=4`, `batchWorkers=5` → `concurrency=4`（受 `perRoomCap` 限制）

### 多房間場景

在多房間場景下，每個 `TransportAdapter` 實例只管理一個房間，無法自動知道系統中有多少房間。每個房間的並行度由 `perRoomCap` 和 `batchWorkers` 決定，通常遠小於 CPU 核心數。Swift 的 `TaskGroup` 會自動管理任務排隊，即使多個房間同時創建大量任務，系統也只會同時運行約等於 CPU 核心數的任務。

### 配置參數

可以通過以下方法調整並行編碼的參數：

```swift
// 設置最小玩家數閾值
await adapter.setParallelEncodingMinPlayerCount(20)

// 設置批次大小
await adapter.setParallelEncodingBatchSize(12)

// 設置並行度上限
await adapter.setParallelEncodingConcurrencyCaps(
    lowPlayerCap: 2,      // 小房間上限
    highPlayerCap: 4,     // 大房間上限
    highPlayerThreshold: 30  // 切換閾值
)

```

### 效能考量

- **小房間（< 20 玩家）**：不會啟用並行編碼（低於閾值）
- **中等房間（20-30 玩家）**：並行度約 2-3
- **大房間（30+ 玩家）**：並行度約 3-4（受 `perRoomCap` 限制）

Swift 的 `TaskGroup` 會自動管理任務排隊和調度，即使創建大量任務，系統也只會同時運行約等於 CPU 核心數的任務。

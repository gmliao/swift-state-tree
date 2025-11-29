# 多房間架構與配對服務設計

> 本文檔說明 SwiftStateTree 的多房間架構設計、房間管理、配對服務，以及相關的命名與職責分界。
>
> **狀態說明**：
> - 📅 多房間架構：規劃中，目前 `AppContainer` 僅支援單一房間
> - 📅 配對服務：規劃中，尚未實作
> - 📅 配對大廳：規劃中，尚未實作
>
> 相關文檔：
> - [DESIGN_APP_CONTAINER_HOSTING.md](./DESIGN_APP_CONTAINER_HOSTING.md) - AppContainer 與 Hosting 設計
> - [DESIGN_LAND-DSL-ROOM_LIFECYCLE.md](./DESIGN_LAND-DSL-ROOM_LIFECYCLE.md) - 房間生命週期設計

## 設計目標

### 1. 支援多房間架構

- 單一應用可以同時管理多個遊戲房間
- 每個房間有獨立的 `LandKeeper`（actor isolation）
- 房間之間互不干擾，可並行執行
- 支援動態建立和銷毀房間

### 2. 配對服務獨立化

- 配對邏輯（Matchmaking）獨立於房間管理
- 配對服務負責玩家分組、房間選擇、規則匹配
- 房間管理只負責房間的生命週期和狀態管理

### 3. 清晰的命名與職責

- 明確區分「單一房間容器」與「多房間管理器」
- 明確區分「配對服務」與「房間管理」
- 提供清晰的 API 和擴展點

## 架構分層

### 整體架構圖

```
┌─────────────────────────────────────────┐
│  AppContainer (應用層級)                  │
│  - 管理整個應用的生命週期                  │
│  - 路由配置                               │
│  - 服務組裝                               │
└─────────────────────────────────────────┘
           │
           ├─────────────────┬─────────────────┬─────────────────┐
           │                 │                 │                 │
┌──────────▼──────────┐ ┌───▼──────────┐ ┌───▼──────────┐ ┌───▼──────────────┐
│ MatchmakingService │ │ LandManager  │ │ LobbyContainer│ │ Other Services  │
│ (配對服務)          │ │ (房間管理)    │ │ (配對大廳)    │ │ (其他服務)       │
│                    │ │              │ │               │ │                 │
│ - 配對邏輯          │ │ - 管理多個   │ │ - 固定房間    │ │ - Metrics       │
│ - 房間選擇          │ │   遊戲房間   │ │ - 等待配對    │ │ - Logging       │
│ - 規則匹配          │ │ - 路由連線   │ │ - 狀態顯示    │ │ - Persistence   │
└────────────────────┘ └──────────────┘ └───────────────┘ └─────────────────┘
           │                 │
           └─────────┬───────┘
                     │
           ┌─────────▼─────────┐
           │  LandContainer    │
           │  (單一房間容器)    │
           │  - LandKeeper     │
           │  - Transport      │
           │  - State          │
           └───────────────────┘
```

## 核心組件設計

### 1. LandContainer（單一房間容器）

**職責**：
- 管理單一房間的完整生命週期
- 封裝 `LandKeeper`、`TransportAdapter`、`WebSocketTransport`
- 處理該房間的所有連線和訊息

**設計**：

```swift
/// Container for a single Land instance.
///
/// Manages the complete lifecycle of one game room, including:
/// - LandKeeper (state management)
/// - Transport layer (WebSocket connections)
/// - State synchronization
public struct LandContainer<State, ClientEvents, ServerEvents> 
where State: StateNodeProtocol,
      ClientEvents: ClientEventPayload,
      ServerEvents: ServerEventPayload {
    
    public let roomID: RoomID
    public let keeper: LandKeeper<State, ClientEvents, ServerEvents>
    public let transport: WebSocketTransport
    public let transportAdapter: TransportAdapter<State, ClientEvents, ServerEvents>
    
    // Room lifecycle management
    public func join(playerID: PlayerID, sessionID: SessionID, clientID: ClientID) async throws -> JoinDecision
    public func leave(playerID: PlayerID, clientID: ClientID) async
    public func handleAction<A: ActionPayload>(_ action: A, from playerID: PlayerID, sessionID: SessionID) async throws -> AnyCodable
    public func handleEvent(_ event: ClientEvents, from playerID: PlayerID, sessionID: SessionID) async
    
    // State access
    public func currentState() async -> State
}
```

**特點**：
- 每個 `LandContainer` 對應一個獨立的遊戲房間
- `LandKeeper` 是 `actor`，提供 thread-safety
- 房間之間完全隔離，可並行執行

### 2. LandManager（多房間管理器）

**職責**：
- 管理多個 `LandContainer` 實例
- 提供房間的建立、查詢、銷毀
- 路由連線到正確的房間

**設計**：

```swift
/// Manager for multiple game rooms.
///
/// Handles room lifecycle, routing, and provides access to individual rooms.
public actor LandManager<State, ClientEvents, ServerEvents>
where State: StateNodeProtocol,
      ClientEvents: ClientEventPayload,
      ServerEvents: ServerEventPayload {
    
    private var rooms: [RoomID: LandContainer<State, ClientEvents, ServerEvents>] = [:]
    private let landFactory: (RoomID) -> LandDefinition<State, ClientEvents, ServerEvents>
    private let initialStateFactory: (RoomID) -> State
    
    /// Get or create a room
    public func getOrCreateRoom(roomID: RoomID) async -> LandContainer<State, ClientEvents, ServerEvents>
    
    /// Get existing room (returns nil if not exists)
    public func getRoom(roomID: RoomID) async -> LandContainer<State, ClientEvents, ServerEvents>?
    
    /// Remove a room
    public func removeRoom(roomID: RoomID) async
    
    /// List all active rooms
    public func listRooms() async -> [RoomID]
    
    /// Get room statistics
    public func getRoomStats(roomID: RoomID) async -> RoomStats?
}
```

**特點**：
- 使用 `actor` 確保 thread-safety
- 支援動態建立和銷毀房間
- 提供房間查詢和統計功能
- 支援並行處理多個房間的操作（tick、事件處理等）

**並行執行支援**：

`LandManager` 提供並行處理多個房間的方法：

```swift
public actor LandManager<State, ClientEvents, ServerEvents> {
    // ... existing code ...
    
    /// Tick all rooms in parallel
    ///
    /// All rooms' tick handlers are executed concurrently.
    /// Each room's LandKeeper is an independent actor, allowing true parallelism.
    public func tickAllRooms() async {
        let roomContainers = await getAllRooms()
        
        await withTaskGroup(of: Void.self) { group in
            for (_, container) in roomContainers {
                group.addTask { [container] in
                    await container.keeper.tick()
                }
            }
        }
    }
    
    /// Process pending events for all rooms in parallel
    public func processEventsForAllRooms() async {
        let roomContainers = await getAllRooms()
        
        await withTaskGroup(of: Void.self) { group in
            for (_, container) in roomContainers {
                group.addTask { [container] in
                    await container.processPendingEvents()
                }
            }
        }
    }
    
    private func getAllRooms() async -> [(RoomID, LandContainer<State, ClientEvents, ServerEvents>)] {
        return Array(rooms)
    }
}
```

### 3. MatchmakingService（配對服務）

**職責**：
- 接收玩家的配對請求
- 根據規則（等級、區域、遊戲模式等）將玩家分組
- 決定要建立新房間或加入現有房間
- 返回房間資訊給玩家

**設計**：

```swift
/// Matchmaking service for player matching and room assignment.
///
/// Independent from room management, focuses on matching logic.
public actor MatchmakingService {
    private let landManager: LandManager
    private var waitingPlayers: [PlayerID: MatchmakingRequest] = [:]
    
    public struct MatchmakingPreferences: Sendable {
        public let gameMode: String
        public let minLevel: Int?
        public let maxLevel: Int?
        public let region: String?
        public let maxWaitTime: Duration?
    }
    
    public enum MatchmakingResult: Sendable {
        case matched(roomID: RoomID)
        case queued(position: Int)
        case failed(reason: String)
    }
    
    /// Request matchmaking
    public func matchmake(
        playerID: PlayerID,
        preferences: MatchmakingPreferences
    ) async throws -> MatchmakingResult
    
    /// Cancel matchmaking request
    public func cancelMatchmaking(playerID: PlayerID) async
    
    /// Get matchmaking status
    public func getStatus(playerID: PlayerID) async -> MatchmakingStatus?
}
```

**特點**：
- 獨立於 `LandManager`，職責清晰
- 可以實作複雜的配對演算法
- 支援佇列管理和取消配對

### 4. LobbyContainer（配對大廳）

**職責**：
- 提供一個固定的「配對大廳」房間
- 玩家等待配對時的臨時空間
- 顯示配對狀態、等待中的玩家列表
- 處理配對相關的 Action/Event

**設計**：

```swift
/// Container for the matchmaking lobby (a special fixed room).
///
/// All players waiting for matchmaking join this lobby first.
public struct LobbyContainer {
    public let container: LandContainer<LobbyState, LobbyClientEvents, LobbyServerEvents>
    
    /// Join the lobby
    public func join(playerID: PlayerID, sessionID: SessionID, clientID: ClientID) async throws
    
    /// Leave the lobby
    public func leave(playerID: PlayerID, clientID: ClientID) async
    
    /// Request matchmaking (via Action)
    public func requestMatchmaking(
        playerID: PlayerID,
        preferences: MatchmakingPreferences
    ) async throws -> MatchmakingResult
}
```

**特點**：
- 是一個特殊的固定房間（不會被銷毀）
- 使用標準的 `LandContainer`，但狀態和邏輯專門用於配對
- 可以顯示等待中的玩家、配對進度等資訊

### 5. AppContainer（應用層級容器）

**職責**：
- 管理整個應用的生命週期
- 組裝所有服務（MatchmakingService、LandManager、LobbyContainer）
- 配置路由和 HTTP/WebSocket endpoints
- 提供統一的啟動和關閉介面

**設計**：

```swift
/// Application-level container managing all services.
///
/// Coordinates MatchmakingService, LandManager, LobbyContainer, and routing.
public struct AppContainer {
    public let matchmakingService: MatchmakingService
    public let landManager: LandManager
    public let lobbyContainer: LobbyContainer
    public let router: Router
    public let configuration: Configuration
    
    /// Create a multi-room server
    public static func makeMultiRoomServer(
        configuration: Configuration,
        landFactory: @escaping (RoomID) -> LandDefinition,
        initialStateFactory: @escaping (RoomID) -> State,
        // ... other parameters
    ) async throws -> AppContainer
    
    /// Create a single-room server (backward compatibility)
    public static func makeSingleRoomServer(
        configuration: Configuration,
        land: LandDefinition,
        initialState: State,
        // ... other parameters
    ) async throws -> AppContainer
    
    /// Run the server
    public func run() async throws
}
```

**特點**：
- 支援單房間和多房間兩種模式
- 向後兼容現有的單房間 API
- 提供統一的服務管理

## 命名規範

### 當前命名問題

目前 `AppContainer` 的名稱暗示是「整個 App 的容器」，但實際上只管理一個房間。這在多房間架構下會造成混淆。

### 建議的命名

| 當前名稱 | 建議名稱 | 說明 |
|---------|---------|------|
| `AppContainer` | `LandContainer` | 單一房間容器（目前 `AppContainer` 的功能） |
| - | `LandManager` | 多房間管理器（新組件） |
| - | `MatchmakingService` | 配對服務（新組件） |
| - | `LobbyContainer` | 配對大廳容器（新組件） |
| - | `AppContainer` | 應用層級容器（管理所有服務） |

### 遷移策略

1. **階段 1：新增新組件**
   - 實作 `LandContainer`、`LandManager`、`MatchmakingService`、`LobbyContainer`
   - 保留現有 `AppContainer` 作為單房間模式的便利方法

2. **階段 2：重構現有 API**
   - 將 `AppContainer` 重構為應用層級容器
   - 提供 `makeSingleRoomServer()` 作為向後兼容的便利方法
   - 提供 `makeMultiRoomServer()` 作為新的多房間 API

3. **階段 3：標記為 deprecated（可選）**
   - 如果決定完全移除單房間模式，可以標記為 deprecated
   - 提供遷移指南

## 工作流程範例

### 1. 玩家配對流程

```swift
// 1. 玩家連線到配對大廳
let lobby = await appContainer.lobbyContainer
try await lobby.join(playerID: playerID, sessionID: sessionID, clientID: clientID)

// 2. 玩家發送配對請求
let result = try await lobby.requestMatchmaking(
    playerID: playerID,
    preferences: MatchmakingPreferences(
        gameMode: "battle-royale",
        minLevel: 10,
        maxLevel: 50
    )
)

// 3. 配對服務處理
switch result {
case .matched(let roomID):
    // 4. 配對成功，通知玩家
    await lobby.sendEvent(.matchFound(roomID: roomID), to: .player(playerID))
    
    // 5. 玩家連線到遊戲房間
    let gameRoom = await appContainer.landManager.getOrCreateRoom(roomID: roomID)
    try await gameRoom.join(playerID: playerID, sessionID: sessionID, clientID: clientID)
    
case .queued(let position):
    // 等待配對中
    await lobby.sendEvent(.queued(position: position), to: .player(playerID))
    
case .failed(let reason):
    await lobby.sendEvent(.matchmakingFailed(reason: reason), to: .player(playerID))
}
```

### 2. 直接加入指定房間

```swift
// 玩家知道房間 ID，直接加入
let roomID = RoomID("room-123")
let gameRoom = await appContainer.landManager.getOrCreateRoom(roomID: roomID)
try await gameRoom.join(playerID: playerID, sessionID: sessionID, clientID: clientID)
```

### 3. 房間路由

```swift
// WebSocket 連線時，從 URL 參數或訊息中提取 roomID
router.ws("/game/:roomID") { inbound, outbound, context in
    let roomID = RoomID(context.parameters.get("roomID") ?? "default")
    let gameRoom = await appContainer.landManager.getOrCreateRoom(roomID: roomID)
    
    // 路由到對應的房間
    await gameRoom.handleConnection(inbound: inbound, outbound: outbound, context: context)
}
```

## 並行執行模式

### 設計原則

Swift 的 actor 模型提供了天然的並行執行能力：
- 每個 `LandKeeper` 是獨立的 `actor` 實例
- 不同 actor 實例之間的操作可以並行執行
- 同一個 actor 內的操作會序列化（確保 thread-safety）

### 執行模式對比

#### ❌ 模式 1：序列化執行（不推薦）

```swift
// 這會序列化執行（一個接一個）
Task {
    for room in rooms {
        await room.keeper.tick()        // 等待 Room 1 完成
        await room.keeper.handleEvent() // 等待 Room 1 完成
        // 然後才處理 Room 2...
    }
}
```

**問題**：房間會一個接一個處理，無法利用多核心 CPU，效能差。

#### ✅ 模式 2：並行執行（推薦）

使用 `withTaskGroup` 讓所有房間並行執行：

```swift
// ✅ 所有房間並行執行
await withTaskGroup(of: Void.self) { group in
    for room in rooms {
        group.addTask {
            // 每個房間在自己的 task 中執行
            // 因為是不同的 actor，可以並行執行
            await room.keeper.tick()
            await room.keeper.handleEvent()
        }
    }
    // 等待所有房間完成
}
```

**優勢**：
- 充分利用多核心 CPU
- 所有房間同時處理，延遲低
- Swift runtime 自動管理 thread pool

### 實際應用範例

#### 1. 定期 Tick 所有房間

```swift
/// Scheduler for periodic room ticks
actor RoomTickScheduler {
    private let landManager: LandManager
    private var tickTask: Task<Void, Never>?
    
    init(landManager: LandManager) {
        self.landManager = landManager
    }
    
    /// Start periodic ticks for all rooms
    func startPeriodicTicks(interval: Duration) {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: interval)
                
                // 並行 tick 所有房間
                await landManager.tickAllRooms()
            }
        }
    }
    
    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }
}
```

#### 2. 批次處理房間事件

```swift
extension LandManager {
    /// Process events for all rooms in parallel
    ///
    /// This method processes pending events for all active rooms concurrently.
    /// Each room's event handling is independent and can run in parallel.
    public func processEventsForAllRooms() async {
        let roomContainers = await getAllRooms()
        
        await withTaskGroup(of: Void.self) { group in
            for (roomID, container) in roomContainers {
                group.addTask { [container] in
                    // 處理該房間的待處理事件
                    await container.processPendingEvents()
                }
            }
        }
    }
}
```

#### 3. 並行執行流程示意圖

```
時間軸 →
│
├─ LandManager.tickAllRooms() 被呼叫
│  └─ 取得所有房間（序列化，很快）
│
├─ withTaskGroup 啟動並行執行
│  │
│  ├─ Task 1: Room 1.tick() ──────────────┐
│  │  └─ LandKeeper actor (Room 1)       │
│  │                                      │
│  ├─ Task 2: Room 2.tick() ──────────────┤ 並行執行
│  │  └─ LandKeeper actor (Room 2)       │ （不同 actor）
│  │                                      │
│  ├─ Task 3: Room 3.tick() ──────────────┤
│  │  └─ LandKeeper actor (Room 3)       │
│  │                                      │
│  └─ Task N: Room N.tick() ──────────────┘
│     └─ LandKeeper actor (Room N)
│
└─ 等待所有 task 完成
```

### 關鍵點

1. **LandManager 的操作是序列化的**：
   - 取得房間列表的操作會序列化（因為是 actor）
   - 但這個操作通常很快（只是讀取字典）

2. **不同房間的操作可以並行**：
   - 每個房間的 `LandKeeper` 是獨立的 actor
   - 不同 actor 之間的操作可以並行執行
   - Swift runtime 會自動管理 thread pool

3. **同一個房間內的操作是序列化的**：
   - 同一個 `LandKeeper` actor 內的操作會序列化
   - 這確保了房間狀態的一致性

4. **使用 TaskGroup 的最佳實踐**：
   - 使用 `withTaskGroup` 來並行處理多個房間
   - 避免使用 `forEach` + `await`（會序列化）
   - 對於固定數量的房間，也可以使用 `async let`

### 效能考量

- **並行度**：理論上可以同時處理的房間數量等於 CPU 核心數
- **記憶體**：每個房間的狀態是獨立的，不會互相影響
- **延遲**：並行執行可以大幅降低整體處理延遲
- **擴展性**：可以輕鬆處理數百甚至數千個房間（取決於 CPU 核心數）

### 實作注意事項

1. **避免在 TaskGroup 中持有 actor 引用過久**：
   ```swift
   // ✅ 正確：在 task 開始時取得 snapshot
   group.addTask { [container] in
       await container.keeper.tick()
   }
   
   // ❌ 錯誤：在 task 外部持有引用
   let container = await landManager.getRoom(roomID)
   group.addTask {
       await container.keeper.tick() // container 可能已經過期
   }
   ```

2. **處理錯誤**：
   ```swift
   await withTaskGroup(of: Result<Void, Error>.self) { group in
       for room in rooms {
           group.addTask {
               do {
                   await room.keeper.tick()
                   return .success(())
               } catch {
                   return .failure(error)
               }
           }
       }
       
       // 收集結果並處理錯誤
       for await result in group {
           if case .failure(let error) = result {
               // 記錄錯誤，但不中斷其他房間的處理
               logger.error("Room tick failed: \(error)")
           }
       }
   }
   ```

3. **限制並行度（可選）**：
   ```swift
   // 如果需要限制同時處理的房間數量
   let maxConcurrency = min(rooms.count, ProcessInfo.processInfo.processorCount)
   await withTaskGroup(of: Void.self) { group in
       for (index, room) in rooms.enumerated() {
           if index >= maxConcurrency {
               // 等待一個任務完成後再添加新的
               await group.next()
           }
           group.addTask {
               await room.keeper.tick()
           }
       }
   }
   ```

## 實作優先順序

### Phase 1：基礎多房間支援（優先）

1. **重構 `AppContainer`**
   - 將現有功能提取為 `LandContainer`
   - 實作 `LandManager` 管理多個 `LandContainer`
   - 提供向後兼容的 API

2. **房間路由**
   - 支援從 URL 參數或訊息中提取 `roomID`
   - 路由連線到正確的房間

3. **房間生命週期**
   - 動態建立和銷毀房間
   - 房間空閒時自動清理

4. **並行執行支援**（✅ 已設計）
   - 實作 `LandManager.tickAllRooms()` 並行處理所有房間的 tick
   - 實作 `LandManager.processEventsForAllRooms()` 並行處理所有房間的事件
   - 使用 `withTaskGroup` 確保真正的並行執行
   - 提供 `RoomTickScheduler` 定期並行 tick 所有房間

### Phase 2：配對服務（後續）

1. **MatchmakingService**
   - 實作基本的配對邏輯
   - 支援簡單的規則匹配

2. **LobbyContainer**
   - 實作配對大廳
   - 顯示等待狀態和配對進度

### Phase 3：進階功能（未來）

1. **進階配對演算法**
   - 技能匹配（ELO、MMR）
   - 區域匹配
   - 隊伍平衡

2. **房間持久化**
   - 房間狀態快照
   - 伺服器重啟後恢復

3. **監控和統計**
   - 房間使用率
   - 配對成功率
   - 效能指標

## 總結

### 設計原則

1. **職責分離**：
   - 配對服務獨立於房間管理
   - 單一房間容器獨立於多房間管理器
   - 應用層級容器協調所有服務

2. **可擴展性**：
   - 支援從單房間擴展到多房間
   - 配對邏輯可以獨立演進
   - 房間管理可以獨立優化

3. **向後兼容**：
   - 保留現有單房間 API
   - 提供平滑的遷移路徑

### 當前狀態

- 📅 **多房間架構**：規劃中，需要實作 `LandContainer` 和 `LandManager`
- 📅 **配對服務**：規劃中，需要實作 `MatchmakingService`
- 📅 **配對大廳**：規劃中，需要實作 `LobbyContainer`
- ✅ **單房間模式**：已實作，透過 `AppContainer` 提供

### 下一步

1. 實作 `LandContainer` 提取現有 `AppContainer` 的功能
2. 實作 `LandManager` 管理多個房間
3. 更新 `AppContainer` 支援多房間模式
4. 提供向後兼容的 API


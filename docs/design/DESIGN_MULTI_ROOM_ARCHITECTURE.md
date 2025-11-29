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


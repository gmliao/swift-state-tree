# 多房間架構與配對服務設計

> 本文檔說明 SwiftStateTree 的多房間架構設計、房間管理、配對服務，以及相關的命名與職責分界。
>
> **狀態說明**：
> - ✅ 多房間架構：已部分實作，`LandManager`、`LandRouter`、`LandContainer` 已實作
> - ✅ `AppContainer`（未來 `LandServer`）：已支援單房間和多房間兩種模式
> - 📅 配對服務：規劃中，`MatchmakingService` 已實作但功能仍在擴展
> - 📅 配對大廳：規劃中，`LobbyContainer` 已實作但功能仍在擴展
>
> 相關文檔：
> - [DESIGN_APP_CONTAINER_HOSTING.md](./DESIGN_APP_CONTAINER_HOSTING.md) - AppContainer 與 Hosting 設計
> - [DESIGN_STATE_BINDING_AND_INITIALIZATION.md](./DESIGN_STATE_BINDING_AND_INITIALIZATION.md) - State 綁定與初始化設計（包含 LandRealm）
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
│  LandServer<State> (應用層級)             │
│  (原 AppContainer<State>)                │
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
/// Manages the complete lifecycle of one land, including:
/// - LandKeeper (state management)
/// - Transport layer (WebSocket connections)
/// - State synchronization
///
/// **Note**: This is a value type that holds references to the actor-based components.
public struct LandContainer<State: StateNodeProtocol>: Sendable {
    public let landID: LandID
    public let keeper: LandKeeper<State>
    public let transport: WebSocketTransport
    public let transportAdapter: TransportAdapter<State>
    
    /// Get the current state of the land.
    public func currentState() async -> State
    
    /// Get statistics about this land.
    public func getStats(createdAt: Date) async -> LandStats
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
/// Manager for multiple game lands.
///
/// Handles land lifecycle, routing, and provides access to individual lands.
/// All operations are thread-safe through actor isolation.
///
/// Supports parallel execution of operations across multiple lands using TaskGroup.
public actor LandManager<State: StateNodeProtocol>: LandManagerProtocol {
    private var lands: [LandID: LandContainer<State>] = [:]
    private let landFactory: (LandID) -> LandDefinition<State>
    private let initialStateFactory: (LandID) -> State
    
    /// Get or create a land with the specified ID.
    public func getOrCreateLand(
        landID: LandID,
        definition: LandDefinition<State>,
        initialState: State
    ) async -> LandContainer<State>
    
    /// Get existing land (returns nil if not exists)
    public func getLand(landID: LandID) async -> LandContainer<State>?
    
    /// Remove a land
    public func removeLand(landID: LandID) async
    
    /// List all active lands
    public func listLands() async -> [LandID]
    
    /// Get land statistics
    public func getLandStats(landID: LandID) async -> LandStats?
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
public actor LandManager<State: StateNodeProtocol> {
    // ... existing code ...
    
    /// Tick all lands in parallel
    ///
    /// All lands' tick handlers are executed concurrently.
    /// Each land's LandKeeper is an independent actor, allowing true parallelism.
    public func tickAllLands() async {
        let landContainers = await getAllLands()
        
        await withTaskGroup(of: Void.self) { group in
            for (_, container) in landContainers {
                group.addTask { [container] in
                    await container.keeper.tick()
                }
            }
        }
    }
    
    /// Process pending events for all lands in parallel
    public func processEventsForAllLands() async {
        let landContainers = await getAllLands()
        
        await withTaskGroup(of: Void.self) { group in
            for (_, container) in landContainers {
                group.addTask { [container] in
                    // Process events through TransportAdapter
                    // (Implementation depends on TransportAdapter API)
                }
            }
        }
    }
    
    private func getAllLands() async -> [(LandID, LandContainer<State>)] {
        return Array(lands)
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
/// Matchmaking service for player matching and land assignment.
///
/// Independent from land management, focuses on matching logic.
public actor MatchmakingService {
    private let landManager: LandManager
    private var waitingPlayers: [PlayerID: MatchmakingRequest] = [:]
    
    public struct MatchmakingPreferences: Sendable {
        public let landType: String
        public let minLevel: Int?
        public let maxLevel: Int?
        public let region: String?
        public let maxWaitTime: Duration?
    }
    
    public enum MatchmakingResult: Sendable {
        case matched(landID: LandID)
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

**位置**: `Sources/SwiftStateTreeTransport/LobbyContainer.swift`

**職責**：
- 提供配對大廳功能（大廳是特殊的 Land）
- 整合 MatchmakingService 進行自動配對
- 支援客戶端自由創建房間
- 支援客戶端手動選擇房間加入
- 追蹤並推送 land 列表變化（類似 Colyseus LobbyRoom）

**設計**：

```swift
/// Container for lobby lands (special lands for matchmaking and room management).
public struct LobbyContainer<State: StateNodeProtocol, Registry: LandManagerRegistry>: Sendable {
    public let container: LandContainer<State>
    private let matchmakingService: MatchmakingService<State, Registry>
    private let landManagerRegistry: Registry
    private let landTypeRegistry: LandTypeRegistry<State>
    
    /// Request matchmaking (automatic matching)
    public func requestMatchmaking(
        playerID: PlayerID,
        preferences: MatchmakingPreferences
    ) async throws -> MatchmakingResult
    
    /// Create a new land (client can freely create)
    public func createLand(
        playerID: PlayerID,
        landType: String,
        landName: String? = nil,
        maxPlayers: Int? = nil
    ) async throws -> LandID
    
    /// Manually join a specific land
    public func joinLand(
        playerID: PlayerID,
        landID: LandID
    ) async -> Bool
    
    /// Update land list by querying all available lands
    public func updateLandList() async -> [AvailableLand]
}
```

**特點**：
- 大廳是特殊的 Land，透過 `LandManager` 統一管理
- 使用 landID 命名約定區分大廳（如 `lobby-asia`、`lobby-europe`）
- 支援多個大廳模式（每個大廳有獨立的配對隊列）
- 整合 MatchmakingService 進行自動配對
- 支援 land 列表追蹤和推送（類似 Colyseus LobbyRoom）
- 結果透過 Server Event 推送給玩家（無需 polling）

### 5. LandServer（應用層級容器）

**職責**：
- 管理整個應用的生命週期
- 組裝所有服務（MatchmakingService、LandManager、LobbyContainer、LandRouter）
- 配置路由和 HTTP/WebSocket endpoints
- 提供統一的啟動和關閉介面

**設計**：

```swift
/// Application-level server managing all services for a specific State type.
///
/// Coordinates LandManager, LandRouter, and routing.
/// Supports both single-room and multi-room modes.
///
/// **Note**: `AppContainer<State>` is an alias for `LandServer<State>`.
/// The naming migration is in progress (see DESIGN_STATE_BINDING_AND_INITIALIZATION.md).
public struct LandServer<State: StateNodeProtocol> {
    public let landManager: LandManager<State>?
    public let landRouter: LandRouter<State>?
    public let router: Router
    public let configuration: Configuration
    
    /// Create a multi-room server
    public static func makeMultiRoomServer(
        configuration: Configuration,
        landFactory: @escaping @Sendable (LandID) -> LandDefinition<State>,
        initialStateFactory: @escaping @Sendable (LandID) -> State,
        // ... other parameters
    ) async throws -> LandServer
    
    /// Create a single-room server
    public static func makeServer(
        configuration: Configuration,
        land: LandDefinition<State>,
        initialState: State,
        // ... other parameters
    ) async throws -> LandServer
    
    /// Run the server
    public func run() async throws
}

// AppContainer is an alias for LandServer (migration in progress)
public typealias AppContainer<State> = LandServer<State>
```

**特點**：
- ✅ **支援單房間和多房間兩種模式**
  - 單房間模式：使用 `makeServer`，固定一個 land 實例
  - 多房間模式：使用 `makeMultiRoomServer`，動態創建多個 land
- ✅ **已實作**：`LandManager`、`LandRouter`、`LandContainer` 已實作
- 向後兼容現有的單房間 API
- 提供統一的服務管理

## 命名規範

### 命名層級

SwiftStateTree 採用統一的 "Land" 命名概念，從底層到上層保持一致：

```
LandRealm                  → 應用層級（管理所有 land types 和 State 類型，統一入口）
    ↓
LandServer<State>          → 遊戲類型層級（服務一個 State 類型的所有 lands，可跨機器）
    ↓
LandManager<State>         → 房間管理層級（管理多個房間，distributed actor）
    ↓
LandRouter<State>          → 路由層級（路由連線到正確的房間）
    ↓
LandContainer<State>       → 房間層級（單一房間容器）
    ↓
LandKeeper<State>          → 狀態管理層級（單一房間的狀態，distributed actor）
    ↓
Land (LandDefinition)      → 規則定義層級（遊戲規則）
```

### 命名遷移策略

為了保持向後兼容，`AppContainer<State>` 將作為 `LandServer<State>` 的別名：

```swift
// 階段 1：新增 LandServer，保留 AppContainer 作為別名
public typealias AppContainer<State> = LandServer<State>

// 階段 2：標記 AppContainer 為 deprecated
@available(*, deprecated, renamed: "LandServer", message: "Use LandServer instead. AppContainer will be removed in a future version.")
public typealias AppContainer<State> = LandServer<State>

// 階段 3：移除 AppContainer（未來版本）
// AppContainer 將被完全移除，只保留 LandServer
```

**遷移時間表**：
- ✅ **當前**：`AppContainer<State>` 作為主要類型（已實作）
- 📅 **階段 1**：引入 `LandServer<State>`，`AppContainer` 作為別名
- 📅 **階段 2**：標記 `AppContainer` 為 deprecated，建議使用 `LandServer`
- 📅 **階段 3**：移除 `AppContainer`，只保留 `LandServer`

**建議**：
- 新代碼應該直接使用 `LandServer<State>`
- 現有代碼可以繼續使用 `AppContainer<State>`，但會收到 deprecation 警告
- 在未來版本中，`AppContainer` 將被完全移除

詳細說明請參考 [DESIGN_STATE_BINDING_AND_INITIALIZATION.md](./DESIGN_STATE_BINDING_AND_INITIALIZATION.md)。

## 工作流程範例

### 1. 玩家配對流程（自動配對）

```swift
// === 伺服器端設定 ===
// 1. 建立 LandManager 和相關服務
let landManager = LandManager<State>(
    landFactory: { landID in ... },
    initialStateFactory: { landID in ... }
)
let registry = SingleLandManagerRegistry(landManager: landManager)
let landTypeRegistry = LandTypeRegistry<State>(...)
let matchmakingService = MatchmakingService(registry: registry, landTypeRegistry: landTypeRegistry)

// 2. 建立大廳
let lobbyContainer = await landManager.getOrCreateLand(
    landID: LandID("lobby-asia"),
    definition: makeLobbyLandDefinition(...),
    initialState: LobbyState()
)

// 3. 包裝為 LobbyContainer
let lobby = LobbyContainer(
    container: lobbyContainer,
    matchmakingService: matchmakingService,
    landManagerRegistry: registry,
    landTypeRegistry: landTypeRegistry
)

// === 客戶端流程 ===
// 1. 玩家連線到大廳 WebSocket
let lobbyWS = WebSocket("ws://host:port/game/lobby-asia")
await lobbyWS.connect()
await lobbyWS.send(JoinMessage(...))

// 2. 玩家發送配對請求（透過 Action）
await lobbyWS.send(ActionMessage(
    action: RequestMatchmakingAction(
        preferences: MatchmakingPreferences(
            landType: "battle-royale",
            minLevel: 10,
            maxLevel: 50
        )
    )
))

// 3. 大廳的 Action handler 呼叫 LobbyContainer.requestMatchmaking()
// 4. LobbyContainer 呼叫 MatchmakingService.matchmake()
// 5. 結果透過 Server Event 推送給玩家（無需 polling）

// 6. 客戶端接收配對結果
lobbyWS.onEvent { event in
    if case .matched(let landID) = event {
        // 配對成功，連接到遊戲房間
        let gameWS = WebSocket("ws://host:port/game/\(landID.stringValue)")
        await gameWS.connect()
        await gameWS.send(JoinMessage(...))
    } else if case .queued(let position) = event {
        // 還在排隊
        updateQueuePosition(position)
    } else if case .failed(let reason) = event {
        // 配對失敗
        showError(reason)
    }
}
```

### 1b. 客戶端創建房間流程

```swift
// === 客戶端流程 ===
// 1. 玩家在大廳中發送創建房間請求（透過 Action）
await lobbyWS.send(ActionMessage(
    action: CreateRoomAction(
        landType: "battle-royale",
        roomName: "My Custom Room",
        maxPlayers: 8
    )
))

// 2. 大廳的 Action handler 呼叫 LobbyContainer.createLand()
// 3. LobbyContainer 使用 LandManagerRegistry 創建新 land
// 4. land 列表更新並推送給所有大廳玩家（LandListEvent.landAdded）

// 5. 客戶端接收 land 列表更新
lobbyWS.onEvent { event in
    if case .landAdded(let land) = event {
        // 新 land 已創建
        addLandToList(land)
    }
}
```

### 1c. 客戶端手動加入房間流程

```swift
// === 客戶端流程 ===
// 1. 玩家從 land 列表中選擇一個 land
let selectedLand = availableLands[0]

// 2. 玩家發送加入 land 請求（透過 Action）
await lobbyWS.send(ActionMessage(
    action: JoinLandAction(landID: selectedLand.landID)
))

// 3. 大廳的 Action handler 呼叫 LobbyContainer.joinLand()
// 4. 驗證 land 存在後，返回成功

// 5. 客戶端連接到遊戲 land
let gameWS = WebSocket("ws://host:port/game/\(selectedLand.landID.stringValue)")
await gameWS.connect()
await gameWS.send(JoinMessage(...))
```

### 2. 直接加入指定 land（不使用大廳）

```swift
// 玩家知道 land ID，直接連接到遊戲 land（跳過大廳）
let landID = LandID("battle-royale-123")
let gameWS = WebSocket("ws://host:port/game/\(landID.stringValue)")
await gameWS.connect()
await gameWS.send(JoinMessage(...))
```

### 3. 多個大廳管理

```swift
// === 伺服器端設定 ===
// 1. 建立多個大廳
let container = try await LandServer<State>.makeMultiRoomServer(
    configuration: config,
    landFactory: { landID in ... },
    initialStateFactory: { landID in ... },
    lobbyIDs: ["lobby-asia", "lobby-europe", "lobby-casual"] // 預先建立多個大廳
)

// 2. 取得特定大廳
let asiaLobby = await container.getLobby(
    landID: LandID("lobby-asia"),
    matchmakingService: matchmakingService,
    landManagerRegistry: registry,
    landTypeRegistry: landTypeRegistry
)

// 3. 列出所有大廳（需要從 LandManager 獲取）
let allLobbies = await container.landManager?.listLands()
// 返回: [LandID("lobby-asia"), LandID("lobby-europe"), LandID("lobby-casual")]
```

### 4. 房間路由

**注意**：實際路由由 `LandRouter<State>` 處理，不需要手動路由。

```swift
// 在 LandServer.makeMultiRoomServer 中，LandRouter 自動處理路由
// WebSocket 連線時，LandRouter 從 Join 訊息中提取 landType 和 landInstanceId
// 路由格式: /game (統一 endpoint)
// Join 訊息格式: { "kind": "join", "payload": { "join": { "landType": "...", "landInstanceId": "..." } } }

// LandRouter 自動處理：
// 1. 接收 WebSocket 連接
// 2. 接收 Join 訊息
// 3. 根據 landType 和 landInstanceId 路由到對應的 land
// 4. 如果 landInstanceId 為 null，創建新的 land
```

**實際實作**（在 `LandRouter` 中）：
- `LandRouter` 使用 `LandTypeRegistry` 根據 `landType` 創建新的 land
- `LandRouter` 使用 `LandManager` 管理現有的 land
- 所有路由邏輯都在 `LandRouter` 內部處理，無需手動配置

### 5. 大廳如何呼叫 MatchmakingService

```swift
// 在 LobbyContainer 中：
public func requestMatchmaking(
    playerID: PlayerID,
    preferences: MatchmakingPreferences
) async throws -> MatchmakingResult {
    // 1. 呼叫 MatchmakingService
    let result = try await matchmakingService.matchmake(
        playerID: playerID,
        preferences: preferences
    )
    
    // 2. 透過 Event 推送結果給玩家
    await sendMatchmakingResult(playerID: playerID, result: result)
    
    return result
}

// 在 LandDefinition 的 Action handler 中：
HandleAction(RequestMatchmakingAction.self) { state, action, ctx in
    // 從 LandServices 取得 LobbyContainer（需要預先註冊）
    guard let lobbyContainer = ctx.services.get(LobbyContainer.self) else {
        return MatchmakingResponse(result: .failed(reason: "LobbyContainer not available"))
    }
    
    // 呼叫 LobbyContainer
    let result = try await lobbyContainer.requestMatchmaking(
        playerID: ctx.playerID,
        preferences: action.preferences
    )
    
    return MatchmakingResponse(result: result)
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
    for (_, container) in lands {
        await container.keeper.tick()        // 等待 Land 1 完成
        // 然後才處理 Land 2...
    }
}
```

**問題**：land 會一個接一個處理，無法利用多核心 CPU，效能差。

#### ✅ 模式 2：並行執行（推薦）

使用 `withTaskGroup` 讓所有 land 並行執行：

```swift
// ✅ 所有 land 並行執行
await withTaskGroup(of: Void.self) { group in
    for (_, container) in lands {
        group.addTask { [container] in
            // 每個 land 在自己的 task 中執行
            // 因為是不同的 actor，可以並行執行
            await container.keeper.tick()
        }
    }
    // 等待所有 land 完成
}
```

**優勢**：
- 充分利用多核心 CPU
- 所有房間同時處理，延遲低
- Swift runtime 自動管理 thread pool

### 實際應用範例

#### 1. 定期 Tick 所有 land

```swift
/// Scheduler for periodic land ticks
actor LandTickScheduler {
    private let landManager: LandManager<State>
    private var tickTask: Task<Void, Never>?
    
    init(landManager: LandManager<State>) {
        self.landManager = landManager
    }
    
    /// Start periodic ticks for all lands
    func startPeriodicTicks(interval: Duration) {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: interval)
                
                // 並行 tick 所有 land
                await landManager.tickAllLands()
            }
        }
    }
    
    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }
}
```

#### 2. 批次處理 land 事件

```swift
extension LandManager {
    /// Process events for all lands in parallel
    ///
    /// This method processes pending events for all active lands concurrently.
    /// Each land's event handling is independent and can run in parallel.
    public func processEventsForAllLands() async {
        let landContainers = await getAllLands()
        
        await withTaskGroup(of: Void.self) { group in
            for (landID, container) in landContainers {
                group.addTask { [container] in
                    // 處理該 land 的待處理事件
                    // (Implementation depends on TransportAdapter API)
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
├─ LandManager.tickAllLands() 被呼叫
│  └─ 取得所有 lands（序列化，很快）
│
├─ withTaskGroup 啟動並行執行
│  │
│  ├─ Task 1: Land 1.tick() ──────────────┐
│  │  └─ LandKeeper actor (Land 1)       │
│  │                                      │
│  ├─ Task 2: Land 2.tick() ──────────────┤ 並行執行
│  │  └─ LandKeeper actor (Land 2)       │ （不同 actor）
│  │                                      │
│  ├─ Task 3: Land 3.tick() ──────────────┤
│  │  └─ LandKeeper actor (Land 3)       │
│  │                                      │
│  └─ Task N: Land N.tick() ──────────────┘
│     └─ LandKeeper actor (Land N)
│
└─ 等待所有 task 完成
```

### 關鍵點

1. **LandManager 的操作是序列化的**：
   - 取得 land 列表的操作會序列化（因為是 actor）
   - 但這個操作通常很快（只是讀取字典）

2. **不同 land 的操作可以並行**：
   - 每個 land 的 `LandKeeper` 是獨立的 actor
   - 不同 actor 之間的操作可以並行執行
   - Swift runtime 會自動管理 thread pool

3. **同一個 land 內的操作是序列化的**：
   - 同一個 `LandKeeper` actor 內的操作會序列化
   - 這確保了 land 狀態的一致性

4. **使用 TaskGroup 的最佳實踐**：
   - 使用 `withTaskGroup` 來並行處理多個 land
   - 避免使用 `forEach` + `await`（會序列化）
   - 對於固定數量的 land，也可以使用 `async let`

### 效能考量

- **並行度**：理論上可以同時處理的 land 數量等於 CPU 核心數
- **記憶體**：每個 land 的狀態是獨立的，不會互相影響
- **延遲**：並行執行可以大幅降低整體處理延遲
- **擴展性**：可以輕鬆處理數百甚至數千個 land（取決於 CPU 核心數）

### 實作注意事項

1. **避免在 TaskGroup 中持有 actor 引用過久**：
   ```swift
   // ✅ 正確：在 task 開始時取得 snapshot
   group.addTask { [container] in
       await container.keeper.tick()
   }
   
   // ❌ 錯誤：在 task 外部持有引用
   let container = await landManager.getLand(landID: landID)
   group.addTask {
       await container.keeper.tick() // container 可能已經過期
   }
   ```

2. **處理錯誤**：
   ```swift
   await withTaskGroup(of: Result<Void, Error>.self) { group in
       for (_, container) in lands {
           group.addTask { [container] in
               do {
                   await container.keeper.tick()
                   return .success(())
               } catch {
                   return .failure(error)
               }
           }
       }
       
       // 收集結果並處理錯誤
       for await result in group {
           if case .failure(let error) = result {
               // 記錄錯誤，但不中斷其他 land 的處理
               logger.error("Land tick failed: \(error)")
           }
       }
   }
   ```

3. **限制並行度（可選）**：
   ```swift
   // 如果需要限制同時處理的 land 數量
   let maxConcurrency = min(lands.count, ProcessInfo.processInfo.processorCount)
   await withTaskGroup(of: Void.self) { group in
       for (index, (_, container)) in lands.enumerated() {
           if index >= maxConcurrency {
               // 等待一個任務完成後再添加新的
               await group.next()
           }
           group.addTask { [container] in
               await container.keeper.tick()
           }
       }
   }
   ```

## 實作優先順序

### Phase 1：基礎多房間支援（✅ 已部分實作）

1. **`LandContainer` 已實作** ✅
   - 封裝 `LandKeeper`、`TransportAdapter`、`WebSocketTransport`
   - 管理單一 land 的完整生命週期

2. **`LandManager` 已實作** ✅
   - 管理多個 `LandContainer` 實例
   - 支援動態建立和銷毀 land
   - 提供 land 查詢和統計功能

3. **`LandRouter` 已實作** ✅
   - 路由連線到正確的 land
   - 支援從 Join 訊息中提取 `landType` 和 `landInstanceId`
   - 使用 `LandTypeRegistry` 根據 `landType` 創建新的 land

4. **`LandServer`（原 `AppContainer`）已實作** ✅
   - 支援單房間模式（`makeServer`）
   - 支援多房間模式（`makeMultiRoomServer`）
   - 提供統一的服務管理

5. **並行執行支援**（✅ 已設計）
   - `LandManager` 可以並行處理多個 land
   - 使用 `withTaskGroup` 確保真正的並行執行
   - 每個 `LandKeeper` 是獨立的 actor，可以並行執行

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

- ✅ **多房間架構**：已部分實作
  - ✅ `LandContainer`：已實作
  - ✅ `LandManager`：已實作
  - ✅ `LandRouter`：已實作
  - ✅ `LandServer`（原 `AppContainer`）：已實作，支援單房間和多房間兩種模式
- ✅ **配對服務**：`MatchmakingService` 已實作，功能仍在擴展
- ✅ **配對大廳**：`LobbyContainer` 已實作，功能仍在擴展
- ✅ **單房間模式**：已實作，透過 `LandServer.makeServer` 提供
- ✅ **多房間模式**：已實作，透過 `LandServer.makeMultiRoomServer` 提供

### 下一步

1. ✅ 實作 `LandContainer`、`LandManager`、`LandRouter`（已完成）
2. ✅ 更新 `LandServer`（原 `AppContainer`）支援多房間模式（已完成）
3. 📅 擴展 `MatchmakingService` 功能
4. 📅 擴展 `LobbyContainer` 功能
5. 📅 實作 `LandRealm` 統一管理多個不同 State 類型的 `LandServer`（見 DESIGN_STATE_BINDING_AND_INITIALIZATION.md）
6. 📅 分布式架構支援（跨伺服器協調）


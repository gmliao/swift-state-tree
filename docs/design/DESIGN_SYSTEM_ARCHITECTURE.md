# 系統架構設計文檔

> 本文檔整合了 SwiftStateTree 的完整系統架構，包括單房間模式、多房間模式、配對服務、管理員功能，以及為 distributed actor 的擴展性設計。

## 目錄

1. [整體架構](#整體架構)
2. [核心組件](#核心組件)
3. [多房間架構](#多房間架構)
4. [配對服務](#配對服務)
5. [管理員功能](#管理員功能)
6. [Distributed Actor 擴展性](#distributed-actor-擴展性)
7. [模組依賴關係](#模組依賴關係)

## 整體架構

### 架構分層

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
│ MatchmakingService │ │ LandManager  │ │ AdminRoutes  │ │ Other Services  │
│ (配對服務)          │ │ (房間管理)    │ │ (管理員API)  │ │ (其他服務)       │
│                    │ │              │ │               │ │                 │
│ - 配對邏輯          │ │ - 管理多個   │ │ - HTTP API    │ │ - Metrics       │
│ - 房間選擇          │ │   遊戲房間   │ │ - 認證授權    │ │ - Logging       │
│ - 規則匹配          │ │ - 路由連線   │ │ - 查詢管理    │ │ - Persistence   │
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
                     │
           ┌─────────▼─────────┐
           │  LobbyContainer    │
           │  (大廳容器)        │
           │  - 配對功能        │
           │  - 房間創建        │
           │  - 房間列表        │
           └───────────────────┘
```

## 核心組件

### 1. LandID

**位置**: `Sources/SwiftStateTree/Runtime/LandID.swift`

**職責**: 
- 提供結構化的 Land 識別符
- 支援 `Codable`、`Hashable`、`Sendable`
- 與 `String` 互轉以保持向後兼容

**設計考量**:
- 為 distributed actor 的 ID 系統做準備
- 支援序列化以跨進程/跨機器使用

### 2. LandKeeperProtocol

**位置**: `Sources/SwiftStateTree/Runtime/LandKeeperProtocol.swift`

**職責**:
- 抽象 `LandKeeper` 的核心操作
- 定義統一的介面，支援未來 distributed actor 替換

**關鍵方法**:
- `currentState() -> State`
- `join(session:clientID:sessionID:services:) async throws -> JoinDecision`
- `leave(playerID:clientID:) async`
- `handleActionEnvelope(_:playerID:clientID:sessionID:) async throws -> AnyCodable`
- `handleClientEvent(_:playerID:clientID:sessionID:) async`

**設計原則**:
- 所有方法參數和返回值必須是 `Sendable` 和 `Codable`
- 為 distributed actor 序列化做準備

### 3. LandKeeper

**位置**: `Sources/SwiftStateTree/Runtime/LandKeeper.swift`

**職責**:
- 管理單一 Land 的權威狀態
- 執行 Land DSL 定義的處理器
- 處理玩家加入/離開、Action/Event、Tick

**實作**:
- 實作 `LandKeeperProtocol`
- 使用 `actor` 確保 thread-safety
- 支援自動關閉（當房間為空時）

## 多房間架構

### 1. LandContainer

**位置**: `Sources/SwiftStateTreeTransport/LandContainer.swift`

**職責**:
- 封裝單一房間的完整生命週期
- 包含 `LandKeeper`、`WebSocketTransport`、`TransportAdapter`
- 提供房間狀態查詢和統計

**設計**:
- 值類型，持有 actor 引用

### 2. LobbyContainer

**位置**: `Sources/SwiftStateTreeTransport/LobbyContainer.swift`

**職責**:
- 包裝 `LandContainer`，提供大廳專屬的功能
- 整合 `MatchmakingService` 進行自動配對
- 支援客戶端自由創建房間
- 支援客戶端手動選擇房間加入
- 追蹤並推送房間列表變化（類似 Colyseus LobbyRoom）

**設計**:
- 值類型，持有 `LandContainer` 和服務引用
- 大廳是特殊的 Land，透過 `LandManager` 統一管理
- 使用 landID 命名約定區分大廳（如 `lobby-asia`、`lobby-europe`）
- 支援多個大廳模式（每個大廳有獨立的配對隊列）

**關鍵方法**:
- `requestMatchmaking(playerID:preferences:) async throws -> MatchmakingResult`
- `createRoom(playerID:landType:roomName:maxPlayers:) async throws -> LandID`
- `joinRoom(playerID:landID:) async -> Bool`
- `updateRoomList() async -> [AvailableRoom]`

**與 MatchmakingService 的整合**:
- LobbyContainer 透過依賴注入接收 MatchmakingService
- 在 Action handler 中呼叫 `requestMatchmaking()`
- 結果透過 Server Event 推送給玩家（無需 polling）
- 使用協議抽象而非具體類型（為 distributed actor 做準備）

### 3. LandManagerProtocol

**位置**: `Sources/SwiftStateTreeTransport/LandManagerProtocol.swift`

**職責**:
- 抽象 `LandManager` 的操作
- 讓 `MatchmakingService` 依賴協議而非具體實作

**關鍵方法**:
- `getOrCreateLand(landID:definition:initialState:) async -> LandContainer`
- `getLand(landID:) async -> LandContainer?`
- `removeLand(landID:) async`
- `listLands() async -> [LandID]`
- `getLandStats(landID:) async -> LandStats?`

### 3. LandManager

**位置**: `Sources/SwiftStateTreeTransport/LandManager.swift`

**職責**:
- 管理多個 `LandContainer` 實例
- 提供房間的建立、查詢、銷毀
- 支援並行執行（使用 `withTaskGroup`）

**設計特點**:
- 使用 `actor` 確保 thread-safety
- 支援動態建立和銷毀房間
- 提供並行 tick 所有 lands 的方法

### 4. AppContainer 多房間模式

**位置**: `Sources/SwiftStateTreeHummingbird/AppContainer.swift`

**新增方法**: `makeMultiRoomServer()`

**功能**:
- 建立多房間模式的伺服器
- 支援從 URL 路徑或查詢參數提取 `landID`
- 路由 WebSocket 連線到對應的 land
- 保留單房間模式的向後兼容 API (`makeServer()`)

## 配對服務

### 1. MatchmakingTypes

**位置**: `Sources/SwiftStateTreeTransport/MatchmakingTypes.swift`

**類型**:
- `MatchmakingPreferences`: 配對偏好設定
- `MatchmakingResult`: 配對結果（matched, queued, failed）
- `MatchmakingStatus`: 配對狀態資訊

### 2. MatchmakingServiceProtocol

**位置**: `Sources/SwiftStateTreeTransport/MatchmakingServiceProtocol.swift`

**職責**:
- 抽象 `MatchmakingService` 的操作介面
- 為未來 distributed actor 支援做準備
- 所有方法參數和返回值都是 `Sendable` 和 `Codable`

**關鍵方法**:
- `matchmake(playerID:preferences:) async throws -> MatchmakingResult`
- `cancelMatchmaking(playerID:) async`
- `getStatus(playerID:) async -> MatchmakingStatus?`

### 3. MatchmakingService

**位置**: `Sources/SwiftStateTreeTransport/MatchmakingService.swift`

**職責**:
- 管理等待配對的玩家佇列（按 landType 分組）
- 實作配對邏輯（使用 MatchmakingStrategy）
- 與 `LandManagerRegistry` 互動以建立/查詢 lands
- 使用 `LandTypeRegistry` 管理不同 land type 的配置

**設計考量**:
- 實作 `MatchmakingServiceProtocol`（未來可替換為 distributed actor）
- 使用 `LandManagerRegistry` 而非具體的 `LandManager` 類型
- 所有通訊介面都是 `Sendable` 和 `Codable`
- 獨立於房間管理，職責清晰
- 每個 land type 有獨立的配對隊列和策略

## 管理員功能

### 1. AdminAuth

**位置**: `Sources/SwiftStateTreeHummingbird/AdminAuth.swift`

**職責**:
- 驗證管理員 JWT 或 API key
- 提取管理員角色（admin, operator, viewer）
- 檢查權限等級

**角色層級**:
- `admin`: 最高權限，可執行所有操作
- `operator`: 可查詢和管理，但限制某些操作
- `viewer`: 僅可查詢，不能修改

### 2. AdminRoutes

**位置**: `Sources/SwiftStateTreeHummingbird/AdminRoutes.swift`

**HTTP Endpoints**:
- `GET /admin/lands`: 列出所有 lands（需要 viewer 權限）
- `GET /admin/lands/:landID`: 查詢特定 land 資訊
- `GET /admin/lands/:landID/stats`: 取得 land 統計資訊
- `POST /admin/lands`: 手動建立 land（需要 admin 權限）
- `DELETE /admin/lands/:landID`: 手動銷毀 land（需要 admin 權限）
- `GET /admin/stats`: 系統統計資訊

## Distributed Actor 擴展性

### 設計原則

1. **協議抽象**: 使用協議（`LandKeeperProtocol`、`LandManagerProtocol`、`MatchmakingServiceProtocol`）而非具體類型
2. **Sendable 和 Codable**: 所有通訊介面的參數和返回值都符合 `Sendable` 和 `Codable`
3. **ID 系統**: 使用結構化的 `LandID` 而非簡單字串
4. **依賴注入**: `MatchmakingService` 依賴 `LandManagerRegistry`，未來可替換為 distributed actor

### 遷移路徑

**目前（單進程模式）**:
- `LandKeeper`: local actor
- `LandManager`: local actor
- `MatchmakingService`: local actor

**未來（多伺服器模式）**:
- `LandKeeper`: distributed actor（實作 `LandKeeperProtocol`）
- `LandManager`: distributed actor（實作 `LandManagerProtocol`）
- `MatchmakingService`: distributed actor（實作 `MatchmakingServiceProtocol`）

**遷移步驟**:
1. 實作 distributed actor 版本的 `LandKeeper`、`LandManager`、`MatchmakingService`（實作對應的 protocol）
2. 更新依賴注入，使用 protocol 類型而非具體類型
3. 配置 distributed actor system（ActorSystem）
4. 更新 ID 系統以支援跨機器定位

### 關鍵設計點

- **MatchmakingService 與 LandManager 的溝通**: 目前使用 `LandManagerRegistry`（protocol），而非具體的 `LandManager<State>` 類型。所有方法參數都是 `Sendable` 和 `Codable`，確保可以跨進程序列化。

- **協議抽象**: 通過協議抽象（`LandKeeperProtocol`、`LandManagerProtocol`、`MatchmakingServiceProtocol`）定義了清晰的介面，未來可以：
  1. 創建 distributed actor 實作對應的 protocol
  2. 更新依賴注入，使用 protocol 類型而非具體類型
  3. 注入 distributed actor 實例
  4. 代碼邏輯無需修改，因為協議介面保持一致

## 模組依賴關係

```
SwiftStateTree (核心)
    ↑
    │
SwiftStateTreeTransport
    ├── 依賴 SwiftStateTree
    ├── 包含: LandContainer, LandManager, LandManagerProtocol, LandManagerRegistry
    ├── 包含: MatchmakingService, MatchmakingServiceProtocol, MatchmakingStrategy
    ├── 包含: LobbyContainer, LobbyTypes, LobbyLandFactory
    ├── 包含: LandTypeRegistry, MatchmakingTypes
    └── 提供: Transport 抽象層、多房間管理、配對服務
    ↑
    │
SwiftStateTreeHummingbird
    ├── 依賴 SwiftStateTree
    ├── 依賴 SwiftStateTreeTransport
    ├── 包含: AppContainer, AdminAuth, AdminRoutes
    └── 提供: Hummingbird 整合
```

### 模組職責

- **SwiftStateTree**: 核心邏輯，不依賴網路
  - Land DSL、StateTree、Sync、Runtime（LandKeeper）
  
- **SwiftStateTreeTransport**: 傳輸抽象層
  - WebSocketTransport、TransportAdapter
  - 多房間管理（LandManager、LandManagerProtocol、LandContainer、LandManagerRegistry）
  - 配對服務（MatchmakingService、MatchmakingServiceProtocol、MatchmakingStrategy、LandTypeRegistry）
  - 大廳功能（LobbyContainer、LobbyTypes、LobbyLandFactory）

- **SwiftStateTreeHummingbird**: Hummingbird 整合
  - AppContainer、路由配置
  - 管理員功能（AdminAuth、AdminRoutes）

## 使用範例

### 單房間模式（向後兼容）

```swift
let container = try await AppContainer.makeServer(
    configuration: config,
    land: myLand,
    initialState: MyGameState()
)
try await container.run()
```

### 多房間模式

```swift
let container = try await AppContainer.makeMultiRoomServer(
    configuration: config,
    landFactory: { landID in
        // 根據 landID 創建對應的 Land definition
        MyGame.makeLand()
    },
    initialStateFactory: { landID in
        // 根據 landID 創建初始狀態
        MyGameState()
    }
)
try await container.run()
```

### 配對服務

```swift
// 建立 LandManager 和 Registry
let landManager = LandManager<State>(...)
let registry = SingleLandManagerRegistry(landManager: landManager)

// 建立 LandTypeRegistry（管理不同 land type 的配置）
let landTypeRegistry = LandTypeRegistry<State>(
    landFactory: { landType, landID in ... },
    initialStateFactory: { landType, landID in ... },
    strategyFactory: { landType in ... }
)

// 建立 MatchmakingService（實作 MatchmakingServiceProtocol）
let matchmakingService = MatchmakingService(registry: registry, landTypeRegistry: landTypeRegistry)

// 建立大廳
let lobbyContainer = await landManager.getOrCreateLand(
    landID: LandID("lobby-asia"),
    definition: makeLobbyLandDefinition(...),
    initialState: LobbyState()
)

// 包裝為 LobbyContainer
let lobby = LobbyContainer(
    container: lobbyContainer,
    matchmakingService: matchmakingService,
    landManagerRegistry: registry,
    landTypeRegistry: landTypeRegistry
)

// 使用配對服務
let result = try await matchmakingService.matchmake(
    playerID: playerID,
    preferences: MatchmakingPreferences(landType: "battle-royale")
)
```

## 總結

本架構設計支援：

1. ✅ **單房間和多房間模式**: 向後兼容的 API
2. ✅ **配對服務**: 獨立的配對邏輯
3. ✅ **管理員功能**: HTTP API 用於查詢和管理
4. ✅ **Distributed Actor 擴展性**: 為未來多伺服器模式預留設計空間
5. ✅ **清晰的模組分層**: 核心、傳輸、整合層分離

未來擴展方向：
- 實作 distributed actor 版本
- 完善配對演算法（ELO、MMR、區域匹配）
- 房間持久化
- 監控和統計系統


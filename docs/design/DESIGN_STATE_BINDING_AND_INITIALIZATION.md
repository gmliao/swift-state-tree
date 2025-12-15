# State 綁定與初始化設計

> 本文檔說明 SwiftStateTree 中 State 綁定的設計考量、初始化流程簡化方案，以及支援不同 State + Land 組合的架構設計。
>
> **狀態說明**：
> - ✅ 當前實作：`LandServer<State>` 綁定單一 State 類型（原 `AppContainer<State>`）
> - 📅 簡化初始化：規劃中
> - 📅 多 State 支援：規劃中（透過 `LandRealm` 封裝）
> - 📅 分布式架構：規劃中（支援 distributed actor）
>
> 相關文檔：
> - [DESIGN_APP_CONTAINER_HOSTING.md](./DESIGN_APP_CONTAINER_HOSTING.md) - AppContainer 與 Hosting 設計
> - [DESIGN_SYSTEM_ARCHITECTURE.md](./DESIGN_SYSTEM_ARCHITECTURE.md) - 系統架構設計
> - [DESIGN_MULTI_ROOM_ARCHITECTURE.md](./DESIGN_MULTI_ROOM_ARCHITECTURE.md) - 多房間架構設計
> - [DESIGN_DISTRIBUTED_ACTORS.md](./DESIGN_DISTRIBUTED_ACTORS.md) - Distributed Actor 擴展性設計

## 命名層級

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

**命名原則**：
- 所有組件都以 "Land" 開頭，保持命名一致性
- 層級清晰：從規則定義到應用層級
- 語義明確：每個組件的職責清楚

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

## 問題背景

### 當前設計的限制

目前的 `LandServer<State>` 設計要求整個應用綁定單一 `State` 類型：

```swift
public struct LandServer<State: StateNodeProtocol> {
    public static func makeMultiRoomServer(
        configuration: Configuration = Configuration(),
        landFactory: @escaping @Sendable (LandID) -> LandDefinition<State>,
        initialStateFactory: @escaping @Sendable (LandID) -> State,
        // ...
    ) async throws -> LandServer
}
```

**限制**：
- 一個 `LandServer` 實例只能處理一種 `State` 類型
- 如果遊戲需要多種不同的 State（例如：棋類遊戲、卡牌遊戲、RPG），需要建立多個 `LandServer` 實例
- 每個 `LandServer` 需要獨立的 WebSocket endpoint 或路由配置

### 為什麼需要綁定 State？

#### 1. Swift 泛型系統的限制

Swift 的泛型系統要求類型在編譯時確定。`LandKeeper<State>` 是 `actor`，需要知道具體的 `State` 類型才能：

- 管理狀態的記憶體佈局
- 確保類型安全
- 支援 `inout` 參數（需要具體類型）

```swift
actor LandKeeper<State: StateNodeProtocol> {
    private var state: State  // 需要具體類型
    
    func handleAction<A: ActionPayload>(
        _ action: A,
        from playerID: PlayerID
    ) async throws -> AnyCodable {
        // 需要知道 State 類型才能調用 handler
        // handler(state: &state, action: action, ctx: ctx)
    }
}
```

#### 2. `inout` 參數的限制

`LandKeeper` 需要修改 `State`，使用 `inout` 參數：

```swift
// 在 LandDefinition 中
Action(SomeAction.self) { state, action, ctx in
    // state 是 inout 參數，需要具體類型
    state.someProperty = newValue
}
```

Swift 的 `inout` 參數**不能使用協議類型**（`any StateNodeProtocol`），必須是具體類型。

#### 3. 類型安全保證

綁定具體的 `State` 類型可以：
- 在編譯時檢查類型匹配
- 避免運行時類型轉換錯誤
- 提供更好的 IDE 支援和自動完成

## 設計方案

### 方案 1：統一 State 結構（推薦用於相似遊戲）

**適用場景**：不同遊戲模式使用相似的 State 結構，只是規則不同。

**設計**：使用統一的 `State` 結構，透過 `StateNode` 組合或可選欄位來支援變化：

```swift
// 統一的 GameState
struct GameState: StateNodeProtocol {
    var gameMode: GameMode  // 區分不同遊戲模式
    var players: [Player]
    var board: Board?       // 棋類遊戲
    var cards: [Card]?      // 卡牌遊戲
    var characters: [Character]?  // RPG
    // ...
}

// 不同的 Land 定義使用相同的 State，但規則不同
let chessLand = LandDefinition<GameState> {
    // 棋類遊戲規則
}

let cardGameLand = LandDefinition<GameState> {
    // 卡牌遊戲規則
}
```

**優點**：
- 只需要一個 `LandServer<GameState>`
- 簡化初始化流程
- 共享狀態結構，減少重複

**缺點**：
- 如果遊戲差異很大，State 會變得複雜
- 可選欄位可能導致記憶體浪費

### 方案 2：多個 LandServer 實例（推薦用於差異大的遊戲）

**適用場景**：不同遊戲類型有完全不同的 State 結構。

**設計**：為每種 State 類型建立獨立的 `LandServer` 實例，使用不同的 WebSocket endpoint：

```swift
// 棋類遊戲
let chessServer = try await LandServer<ChessState>.makeMultiRoomServer(
    configuration: .init(webSocketPath: "/chess"),
    landFactory: { _ in ChessGame.makeLand() },
    initialStateFactory: { _ in ChessState() }
)

// 卡牌遊戲
let cardGameServer = try await LandServer<CardGameState>.makeMultiRoomServer(
    configuration: .init(webSocketPath: "/cardgame"),
    landFactory: { _ in CardGame.makeLand() },
    initialStateFactory: { _ in CardGameState() }
)

// 分別啟動
try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask {
        try await chessServer.run()
    }
    group.addTask {
        try await cardGameServer.run()
    }
}
```

**優點**：
- 每個遊戲類型有獨立的 State 結構
- 清晰的職責分離
- 可以獨立擴展和部署

**缺點**：
- 需要管理多個 `LandServer` 實例
- 每個 endpoint 需要獨立配置

### 方案 3：LandRealm 封裝（推薦用於簡化使用）

**適用場景**：希望簡化初始化流程，讓開發者只需關注 State 和 Land 定義，統一管理所有 land types 和 State 類型。

**設計**：建立高層的 `LandRealm` 封裝，自動管理多個不同 State 類型的 `LandServer` 實例：

```swift
/// High-level realm that manages all land types and State types.
///
/// Automatically creates and manages LandServer instances for different State types.
/// Developers only need to define State and Land, without directly managing LandServer.
/// 
/// **Key Feature**: Can manage multiple LandServer instances with different State types.
/// This is the unified entry point for creating all land states.
///
/// **Note**: Distributed architecture support (multi-server coordination) is planned for future versions.
/// Currently, each server creates its own LandRealm instance independently.
public struct LandRealm {
    private var servers: [String: any AnyLandServer] = [:]
    
    /// Register a land type with its State and Land definitions.
    ///
    /// This method can register LandServer instances with different State types.
    /// Each land type can have its own State type, allowing complete flexibility.
    ///
    /// - Parameters:
    ///   - landType: The land type identifier (e.g., "chess", "cardgame")
    ///   - landFactory: Factory function to create LandDefinition for a given LandID
    ///   - initialStateFactory: Factory function to create initial state for a given LandID
    ///   - webSocketPath: Optional custom WebSocket path (defaults to "/{landType}")
    public mutating func register<State: StateNodeProtocol>(
        landType: String,
        landFactory: @escaping @Sendable (LandID) -> LandDefinition<State>,
        initialStateFactory: @escaping @Sendable (LandID) -> State,
        webSocketPath: String? = nil
    ) async throws {
        let path = webSocketPath ?? "/\(landType)"
        let server = try await LandServer<State>.makeMultiRoomServer(
            configuration: .init(webSocketPath: path),
            landFactory: landFactory,
            initialStateFactory: initialStateFactory
        )
        servers[landType] = server
    }
    
    /// Start all registered LandServer instances
    public func run() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (landType, server) in servers {
                group.addTask {
                    try await server.run()
                }
            }
        }
    }
}

// 使用範例：可以註冊不同 State 類型的 LandServer
var realm = LandRealm()

// 註冊棋類遊戲（使用 ChessState）
try await realm.register(
    landType: "chess",
    landFactory: { _ in ChessGame.makeLand() },
    initialStateFactory: { _ in ChessState() }
)

// 註冊卡牌遊戲（使用 CardGameState，不同的 State 類型）
try await realm.register(
    landType: "cardgame",
    landFactory: { _ in CardGame.makeLand() },
    initialStateFactory: { _ in CardGameState() }
)

// 註冊 RPG 遊戲（使用 RPGState，又是不同的 State 類型）
try await realm.register(
    landType: "rpg",
    landFactory: { _ in RPGGame.makeLand() },
    initialStateFactory: { _ in RPGState() }
)

// 啟動所有 LandServer 實例
try await realm.run()
```

**優點**：
- **統一入口**：可以管理所有 land types 和 State 類型
- **簡化初始化流程**：開發者只需關注 State 和 Land 定義
- **自動管理**：自動管理多個不同 State 類型的 `LandServer` 實例
- **完全靈活性**：每個 land type 可以有自己獨立的 State 類型
- **支援未來分布式架構擴展**（規劃中）

**缺點**：
- 需要類型擦除（type erasure）機制
- 可能增加複雜度

**改進方案：使用協議抽象**

```swift
/// Protocol for type-erased LandServer
protocol AnyLandServer: Sendable {
    func run() async throws
}

extension LandServer: AnyLandServer {
    // LandServer 已經有 run() 方法
}

public struct LandRealm {
    private var servers: [String: any AnyLandServer] = [:]
    
    /// Register a land type with its State and Land definitions.
    ///
    /// **Key Feature**: Can register LandServer instances with different State types.
    /// This allows complete flexibility - each land type can have its own State type.
    public mutating func register<State: StateNodeProtocol>(
        landType: String,
        landFactory: @escaping @Sendable (LandID) -> LandDefinition<State>,
        initialStateFactory: @escaping @Sendable (LandID) -> State,
        webSocketPath: String? = nil
    ) async throws {
        let path = webSocketPath ?? "/\(landType)"
        let server = try await LandServer<State>.makeMultiRoomServer(
            configuration: .init(webSocketPath: path),
            landFactory: landFactory,
            initialStateFactory: initialStateFactory
        )
        servers[landType] = server
    }
    
    public func run() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (landType, server) in servers {
                group.addTask {
                    try await server.run()
                }
            }
        }
    }
}
```

## 簡化初始化流程

### 當前初始化流程的問題

目前的初始化流程需要開發者手動組裝多個組件：

```swift
let server = try await LandServer<State>.makeMultiRoomServer(
    configuration: .init(
        host: "0.0.0.0",
        port: 8080,
        webSocketPath: "/game"
    ),
    landFactory: { landID in
        // 需要根據 landID 決定返回哪個 Land
        if landID.stringValue.hasPrefix("chess-") {
            return ChessGame.makeLand()
        } else if landID.stringValue.hasPrefix("cardgame-") {
            return CardGame.makeLand()
        }
        return DefaultGame.makeLand()
    },
    initialStateFactory: { landID in
        // 需要根據 landID 決定返回哪個 State
        if landID.stringValue.hasPrefix("chess-") {
            return ChessState()
        } else if landID.stringValue.hasPrefix("cardgame-") {
            return CardGameState()
        }
        return DefaultGameState()
    }
)
```

**問題**：
- 需要手動解析 `landID` 來決定返回哪個 Land/State
- 如果有多種 State 類型，無法在同一個 `LandServer` 中處理
- 初始化邏輯複雜，容易出錯

### 簡化方案

#### 方案 A：基於 `landType` 的路由（推薦）

使用 `LandTypeRegistry` 來管理不同 `landType` 的配置：

```swift
// 定義 land type registry（使用 factory 函數模式）
let landTypeRegistry = LandTypeRegistry<State>(
    landFactory: { landType, landID in
        switch landType {
        case "chess":
            return ChessGame.makeLand()
        case "cardgame":
            return CardGame.makeLand()
        default:
            return DefaultGame.makeLand()
        }
    },
    initialStateFactory: { landType, landID in
        switch landType {
        case "chess":
            return ChessState()
        case "cardgame":
            return CardGameState()
        default:
            return DefaultGameState()
        }
    },
    strategyFactory: { landType in
        switch landType {
        case "chess":
            return ChessMatchmakingStrategy()
        case "cardgame":
            return CardGameMatchmakingStrategy()
        default:
            return DefaultMatchmakingStrategy()
        }
    }
)

// 注意：LandTypeRegistry 綁定單一 State 類型，所以不適合直接用於 LandRealm
// LandRealm 使用 register 方法直接註冊不同 State 類型的 LandServer
<｜tool▁calls▁begin｜><｜tool▁call▁begin｜>
read_file

#### 方案 B：Builder Pattern

使用 Builder Pattern 來簡化初始化：

```swift
let realm = try await LandRealmBuilder()
    .addLandType(
        landType: "chess",
        stateType: ChessState.self,
        land: ChessGame.makeLand(),
        initialState: ChessState()
    )
    .addLandType(
        landType: "cardgame",
        stateType: CardGameState.self,
        land: CardGame.makeLand(),
        initialState: CardGameState()
    )
    .addLandType(
        landType: "rpg",
        stateType: RPGState.self,
        land: RPGGame.makeLand(),
        initialState: RPGState()
    )
    .build(
        configuration: .init(webSocketPath: "/game")
    )

try await realm.run()
```

## 支援不同 State + Land 組合

### 設計目標

1. **統一入口**：`LandRealm` 是統一入口，可以創建所有的 land state
2. **簡化開發者體驗**：開發者只需定義 State 和 Land，不需要直接管理 `LandServer`
3. **自動分類管理**：根據 `landType` 自動分類到對應的 `LandServer`
4. **支援多種 State 類型**：可以管理多個不同 State 類型的 `LandServer` 實例
5. **分布式支援**：每個伺服器創建自己的 `LandRealm`（跨伺服器協調機制仍在設計中）

### 架構設計

#### 單一伺服器架構

```
┌─────────────────────────────────────────┐
│  LandRealm (統一入口)                    │
│  - 管理所有 land types 和 State 類型      │
│  - 可以創建所有的 land state              │
│  - 根據 landType 自動路由                │
│  - 簡化初始化流程                        │
└─────────────────────────────────────────┘
           │
           ├─────────────────┬─────────────────┬─────────────────┐
           │                 │                 │                 │
┌──────────▼──────────┐ ┌───▼──────────┐ ┌───▼──────────┐ ┌───▼──────────────┐
│ LandServer<Chess>    │ │ LandServer    │ │ LandServer   │ │ LandServer      │
│ State>               │ │ <CardGame     │ │ <RPGState>   │ │ <OtherState>    │
│                      │ │ State>        │ │              │ │                 │
│ - /game/chess       │ │ - /game/card │ │ - /game/rpg  │ │ - /game/other   │
│ - LandManager       │ │ - LandManager│ │ - LandManager│ │ - LandManager   │
│ - LandRouter        │ │ - LandRouter │ │ - LandRouter │ │ - LandRouter    │
└─────────────────────┘ └──────────────┘ └──────────────┘ └─────────────────┘
```

**關鍵特性**：
- `LandRealm` 可以管理不同 State 類型的 `LandServer`
- 每個 land type 可以有自己獨立的 State 類型
- 統一入口，可以創建所有的 land state

#### 分布式架構（多伺服器，規劃中）

```
┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐
│  Server 1        │    │  Server 2        │    │  Server 3        │
│                  │    │                  │    │                  │
│  ┌────────────┐  │    │  ┌────────────┐  │    │  ┌────────────┐  │
│  │LandRealm  │  │    │  │LandRealm  │  │    │  │LandRealm  │  │
│  └────────────┘  │    │  └────────────┘  │    │  └────────────┘  │
│       │          │    │       │          │    │       │          │
│       ├──────┐   │    │       ├──────┐   │    │       ├──────┐   │
│       │      │   │    │       │      │   │    │       │      │   │
│  ┌────▼──┐ ┌─▼──┐│    │  ┌────▼──┐ ┌─▼──┐│    │  ┌────▼──┐ ┌─▼──┐│
│  │Land   │ │Land││    │  │Land   │ │Land││    │  │Land   │ │Land││
│  │Server │ │Server││    │  │Server │ │Server││    │  │Server │ │Server││
│  │<Chess>│ │<Card>││    │  │<RPG> │ │<...>││    │  │<...> │ │<...>││
│  └───────┘ └─────┘│    │  └───────┘ └─────┘│    │  └───────┘ └─────┘│
└──────────────────┘    └──────────────────┘    └──────────────────┘
```

**分布式架構特點**（規劃中）：
- 每個伺服器創建自己的 `LandRealm` 實例
- 每個 `LandRealm` 管理該伺服器上的 `LandServer` 實例（可以包含不同 State 類型）
- 多個 `LandRealm` 之間的協調機制（如 MatchmakingService 整合）仍在設計中
- 適合水平擴展和故障隔離

**注意**：分布式架構的具體實作細節（包括跨伺服器協調、MatchmakingService 整合等）仍在規劃中，當前版本每個伺服器獨立運行。

### 實作方案

#### 1. LandTypeRegistry

管理不同 land type 的配置（已實作）：

`LandTypeRegistry<State>` 使用 factory 函數模式，為每個 land type 提供：
- LandDefinition factory
- Initial state factory
- Matchmaking strategy factory

**應用場景**：

1. **在 `LandRouter` 中使用**（主要用途）：
   - 當客戶端發送 Join 請求且沒有指定 `landInstanceId` 時，需要創建新的 land
   - 使用 `landTypeRegistry.getLandDefinition(landType:landID:)` 獲取對應的 `LandDefinition`
   - 使用 `landTypeRegistry.initialStateFactory(landType, landID)` 獲取初始 State
   - 根據 `landType` 動態創建對應的 land 實例

2. **在 `MatchmakingService` 中使用**：
   - 使用 `landTypeRegistry.strategyFactory(landType)` 獲取對應的 `MatchmakingStrategy`
   - 每個 land type 可以有自己獨立的配對策略和規則

3. **在 `LobbyContainer` 中使用**：
   - 用於創建和管理不同類型的 lands
   - 提供 land type 到 LandDefinition 的映射

**限制**：

1. **綁定單一 State 類型**：
   - `LandTypeRegistry<State>` 是泛型的，綁定單一 `State` 類型
   - 所有 land type 必須使用相同的 State 類型
   - 如果不同 land type 需要不同的 State 類型，需要多個 `LandTypeRegistry` 實例

2. **與 `LandManager` 的關係**：
   - `LandTypeRegistry<State>` 必須與 `LandManager<State>` 使用相同的 State 類型
   - 一個 `LandRouter<State>` 只能處理一種 State 類型的所有 land types

3. **Factory 函數簽名**：
   - Factory 函數接受 `(landType: String, landID: LandID)` 參數
   - 必須在 factory 內部根據 `landType` 返回對應的 Land 和 State
   - 如果有多種 State 類型，無法在同一個 `LandTypeRegistry` 中處理

**應用場景**：

1. **在 `LandRouter` 中使用**：
   - 當客戶端發送 Join 請求且沒有指定 `landInstanceId` 時，需要創建新的 land
   - 使用 `landTypeRegistry.getLandDefinition(landType:landID:)` 獲取對應的 `LandDefinition`
   - 使用 `landTypeRegistry.initialStateFactory(landType, landID)` 獲取初始 State
   - 根據 `landType` 動態創建對應的 land 實例

2. **在 `MatchmakingService` 中使用**：
   - 使用 `landTypeRegistry.strategyFactory(landType)` 獲取對應的 `MatchmakingStrategy`
   - 每個 land type 可以有自己獨立的配對策略和規則

3. **在 `LobbyContainer` 中使用**：
   - 用於創建和管理不同類型的 lands
   - 提供 land type 到 LandDefinition 的映射

**限制**：

1. **綁定單一 State 類型**：
   - `LandTypeRegistry<State>` 是泛型的，綁定單一 `State` 類型
   - 所有 land type 必須使用相同的 State 類型
   - 如果不同 land type 需要不同的 State 類型，需要多個 `LandTypeRegistry` 實例

2. **與 `LandManager` 的關係**：
   - `LandTypeRegistry<State>` 必須與 `LandManager<State>` 使用相同的 State 類型
   - 一個 `LandRouter<State>` 只能處理一種 State 類型的所有 land types

3. **Factory 函數簽名**：
   - Factory 函數接受 `(landType: String, landID: LandID)` 參數
   - 必須在 factory 內部根據 `landType` 返回對應的 Land 和 State
   - 如果有多種 State 類型，無法在同一個 `LandTypeRegistry` 中處理

```swift
/// Registry for land types.
///
/// Maps each landType to:
/// - LandDefinition factory (how to create the land)
/// - Initial state factory (how to create initial state)
/// - Matchmaking strategy (how to match users/players)
///
/// Each land type can have its own independent configuration, allowing different
/// matching rules, capacity limits, and behaviors for different types of lands.
public struct LandTypeRegistry<State: StateNodeProtocol>: Sendable {
    /// Factory: (landType, landID) -> LandDefinition
    /// The LandDefinition.id must match the landType.
    public let landFactory: @Sendable (String, LandID) -> LandDefinition<State>
    
    /// Factory: (landType, landID) -> State
    public let initialStateFactory: @Sendable (String, LandID) -> State
    
    /// Factory: landType -> MatchmakingStrategy
    /// Each land type can have its own matching rules.
    public let strategyFactory: @Sendable (String) -> any MatchmakingStrategy
    
    public init(
        landFactory: @escaping @Sendable (String, LandID) -> LandDefinition<State>,
        initialStateFactory: @escaping @Sendable (String, LandID) -> State,
        strategyFactory: @escaping @Sendable (String) -> any MatchmakingStrategy
    ) {
        self.landFactory = landFactory
        self.initialStateFactory = initialStateFactory
        self.strategyFactory = strategyFactory
    }
    
    /// Get LandDefinition for a land type.
    public func getLandDefinition(landType: String, landID: LandID) -> LandDefinition<State> {
        let definition = landFactory(landType, landID)
        assert(definition.id == landType, "LandDefinition.id must match landType")
        return definition
    }
}
```

**使用方式**：

```swift
// 建立 LandTypeRegistry
let landTypeRegistry = LandTypeRegistry<State>(
    landFactory: { landType, landID in
        // 根據 landType 返回對應的 LandDefinition
        switch landType {
        case "chess":
            return ChessGame.makeLand()
        case "cardgame":
            return CardGame.makeLand()
        default:
            return DefaultGame.makeLand()
        }
    },
    initialStateFactory: { landType, landID in
        // 根據 landType 返回對應的初始 State
        switch landType {
        case "chess":
            return ChessState()
        case "cardgame":
            return CardGameState()
        default:
            return DefaultGameState()
        }
    },
    strategyFactory: { landType in
        // 根據 landType 返回對應的 MatchmakingStrategy
        switch landType {
        case "chess":
            return ChessMatchmakingStrategy()
        case "cardgame":
            return CardGameMatchmakingStrategy()
        default:
            return DefaultMatchmakingStrategy()
        }
    }
)
```

**實際使用範例（在 LandRouter 中）**：

```swift
// 在 LandRouter.handleJoinRequest 中
if let instanceId = landInstanceId {
    // Case A: Join existing room
    // 不需要使用 LandTypeRegistry，直接從 LandManager 獲取
    landID = LandID(landType: landType, instanceId: instanceId)
    container = await landManager.getLand(landID: landID)
} else {
    // Case B: Create new room
    landID = LandID.generate(landType: landType)
    
    // 使用 LandTypeRegistry 獲取對應的 LandDefinition 和初始 State
    let definition = landTypeRegistry.getLandDefinition(landType: landType, landID: landID)
    let initialState = landTypeRegistry.initialStateFactory(landType, landID)
    
    container = await landManager.getOrCreateLand(
        landID: landID,
        definition: definition,
        initialState: initialState
    )
}
```

**實際使用範例（在 MatchmakingService 中）**：

```swift
// 在 MatchmakingService.matchmake 中
let landType = preferences.landType

// 使用 LandTypeRegistry 獲取對應的 MatchmakingStrategy
let strategy = landTypeRegistry.strategyFactory(landType)

// 使用策略進行配對
let canMatch = await strategy.canMatch(
    playerPreferences: preferences,
    landStats: stats,
    waitingPlayers: waitingPlayersList
)
```

**注意**：
- `LandTypeRegistry<State>` 是泛型的，綁定單一 State 類型
- 使用 factory 函數模式，而不是註冊表模式
- Factory 函數接受 `(landType, landID)` 參數，可以根據這兩個參數動態創建對應的 Land 和 State
- **主要限制**：所有 land type 必須使用相同的 State 類型
- **定位**：`LandTypeRegistry` 是**底層組件**，用於單一 State 類型的上下文（如 `LandRouter<State>`）
- **與 `LandRealm` 的關係**：`LandRealm` **不使用** `LandTypeRegistry`，因為它需要支援不同 State 類型，而是直接使用 `landFactory` 和 `initialStateFactory`

#### 2. LandServer 的兩種模式

`LandServer<State>`（即 `AppContainer<State>`）提供兩種初始化模式：

**單房間模式（Single-Room Mode）**：
- 使用 `makeServer` 方法
- 固定一個 land 實例，無法動態創建新的 land
- **適用場景**：
  - 測試場景（`makeForTest`）
  - 簡單的單一遊戲實例
  - 不需要多房間管理的場景
- **限制**：無法動態創建新的 land，所有連接都連接到同一個 land

**多房間模式（Multi-Room Mode）**：
- 使用 `makeMultiRoomServer` 方法
- 可以動態創建多個 land 實例
- 使用 `LandManager` 和 `LandRouter` 管理多個 land
- **適用場景**：
  - 生產環境（推薦）
  - 需要支援多個房間/遊戲實例
  - 需要動態創建和管理 land
- **優勢**：靈活、可擴展，支援多房間架構

**注意**：`LandRealm` 使用多房間模式（`makeMultiRoomServer`），因為需要管理多個 land types。

#### 3. LandRealm

統一管理所有 `LandServer` 實例（支援不同 State 類型）：

```swift
/// High-level realm that manages all land types and State types.
///
/// Automatically creates and manages LandServer instances for different State types.
/// Developers only need to define State and Land, without directly managing LandServer.
///
/// **Key Feature**: Can manage multiple LandServer instances with different State types.
/// This is the unified entry point for creating all land states.
///
/// **Note**: Distributed architecture support (multi-server coordination) is planned for future versions.
/// Currently, each server creates its own LandRealm instance independently.
public struct LandRealm {
    private var servers: [String: any AnyLandServer] = [:]
    
    /// Register a land type with its State and Land definitions.
    ///
    /// **Key Feature**: Can register LandServer instances with different State types.
    /// Each land type can have its own State type, allowing complete flexibility.
    ///
    /// **Note**: This method does NOT use `LandTypeRegistry` because `LandTypeRegistry<State>`
    /// is bound to a single State type. Instead, it directly uses `landFactory` and
    /// `initialStateFactory` to support different State types.
    ///
    /// `LandTypeRegistry` is reserved for lower-level components (e.g., `LandRouter<State>`)
    /// that operate within a single State type context.
    ///
    /// - Parameters:
    ///   - landType: The land type identifier (e.g., "chess", "cardgame", "rpg")
    ///   - landFactory: Factory function to create LandDefinition for a given LandID
    ///   - initialStateFactory: Factory function to create initial state for a given LandID
    ///   - webSocketPath: Optional custom WebSocket path (defaults to "/{landType}")
    public mutating func register<State: StateNodeProtocol>(
        landType: String,
        landFactory: @escaping @Sendable (LandID) -> LandDefinition<State>,
        initialStateFactory: @escaping @Sendable (LandID) -> State,
        webSocketPath: String? = nil
    ) async throws {
        let path = webSocketPath ?? "/\(landType)"
        let server = try await LandServer<State>.makeMultiRoomServer(
            configuration: .init(webSocketPath: path),
            landFactory: landFactory,
            initialStateFactory: initialStateFactory
        )
        servers[landType] = server
    }
    
    /// Start all registered LandServer instances
    public func run() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (landType, server) in servers {
                group.addTask {
                    try await server.run()
                }
            }
        }
    }
}
```

**關鍵特性**：
- ✅ **可以管理不同 State 類型的 `LandServer`**：每個 land type 可以有自己獨立的 State 類型
- ✅ **統一入口**：可以創建所有的 land state
- ✅ **簡化使用**：開發者只需定義 State 和 Land，不需要直接管理 `LandServer`
- ✅ **自動管理**：自動管理多個 `LandServer` 實例的生命週期

#### 4. 使用範例

**使用 LandRealm 管理所有 land types（推薦）**：

```swift
// 建立 LandRealm（統一入口，可以創建所有的 land state）
var realm = LandRealm()

// 註冊棋類遊戲（使用 ChessState）
try await realm.register(
    landType: "chess",
    landFactory: { _ in ChessGame.makeLand() },
    initialStateFactory: { _ in ChessState() }
)

// 註冊卡牌遊戲（使用 CardGameState，不同的 State 類型）
try await realm.register(
    landType: "cardgame",
    landFactory: { _ in CardGame.makeLand() },
    initialStateFactory: { _ in CardGameState() }
)

// 註冊 RPG 遊戲（使用 RPGState，又是不同的 State 類型）
try await realm.register(
    landType: "rpg",
    landFactory: { _ in RPGGame.makeLand() },
    initialStateFactory: { _ in RPGState() }
)

// 啟動所有 LandServer 實例
try await realm.run()

// 客戶端連接：
// - ws://host:port/chess/room-123  → 連接到棋類遊戲（ChessState）
// - ws://host:port/cardgame/room-456 → 連接到卡牌遊戲（CardGameState）
// - ws://host:port/rpg/room-789 → 連接到 RPG 遊戲（RPGState）
```

**關鍵特性**：
- ✅ **可以管理不同 State 類型的 `LandServer`**：每個 land type 可以有自己獨立的 State 類型
- ✅ **統一入口**：`LandRealm` 是統一入口，可以創建所有的 land state
- ✅ **簡化使用**：開發者只需定義 State 和 Land，不需要直接管理 `LandServer`

**使用 LandRealm 管理多種 State 類型（推薦，使用多房間模式）**：

```swift
@main
struct LandServerMain {
    static func main() async throws {
        // 使用 LandRealm 統一管理所有不同 State 類型的 LandServer
        var realm = LandRealm()
        
        // 註冊棋類遊戲（ChessState）
        try await realm.register(
            landType: "chess",
            landFactory: { _ in ChessGame.makeLand() },
            initialStateFactory: { _ in ChessState() }
        )
        
        // 註冊卡牌遊戲（CardGameState，不同的 State 類型）
        try await realm.register(
            landType: "cardgame",
            landFactory: { _ in CardGame.makeLand() },
            initialStateFactory: { _ in CardGameState() }
        )
        
        // 註冊 RPG 遊戲（RPGState，又是不同的 State 類型）
        try await realm.register(
            landType: "rpg",
            landFactory: { _ in RPGGame.makeLand() },
            initialStateFactory: { _ in RPGState() }
        )
        
        // 啟動所有 LandServer 實例
        try await realm.run()
    }
}
```

**替代方案：直接管理多個 LandServer（不推薦）**：

如果不想使用 `LandRealm`，也可以直接管理多個 `LandServer` 實例：

```swift
// 1. 建立棋類遊戲的 LandServer
let chessServer = try await LandServer<ChessState>.makeMultiRoomServer(
    configuration: .init(webSocketPath: "/chess"),
    landFactory: { _ in ChessGame.makeLand() },
    initialStateFactory: { _ in ChessState() }
)

// 2. 建立卡牌遊戲的 LandServer
let cardGameServer = try await LandServer<CardGameState>.makeMultiRoomServer(
    configuration: .init(webSocketPath: "/cardgame"),
    landFactory: { _ in CardGame.makeLand() },
    initialStateFactory: { _ in CardGameState() }
)

// 3. 並行啟動所有 LandServer
try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask {
        try await chessServer.run()
    }
    group.addTask {
        try await cardGameServer.run()
    }
}
```

**建議**：使用 `LandRealm` 作為統一入口，可以更簡潔地管理所有 land types 和 State 類型。

**單房間模式使用範例（僅用於簡單場景或測試）**：

```swift
// 單房間模式：固定一個 land 實例
let server = try await LandServer<GameState>.makeServer(
    configuration: .init(webSocketPath: "/game"),
    land: ChessGame.makeLand(),
    initialState: GameState(mode: .chess)
)

try await server.run()

// 所有連接都連接到同一個 land
// - ws://host:port/game → 連接到固定的 chess land
```

**注意**：
- 單房間模式適合測試或簡單場景
- 生產環境建議使用多房間模式（通過 `LandRealm` 或直接使用 `makeMultiRoomServer`）
- `LandRealm` 統一使用多房間模式，因為需要管理多個 land types

**分布式架構說明**（規劃中）：
- 每個伺服器都會創建自己的 `LandRealm` 實例
- 每個 `LandRealm` 管理該伺服器上的 `LandServer` 實例（可以包含不同 State 類型）
- 多個 `LandRealm` 之間的協調機制（包括 MatchmakingService 整合）仍在設計中
- 適合水平擴展和故障隔離

**注意**：分布式架構的具體實作細節（包括跨伺服器協調、MatchmakingService 整合等）仍在規劃中，當前版本每個伺服器獨立運行。

## 與 Colyseus 的比較

### Colyseus 的設計

Colyseus 使用 Schema 定義狀態，支援動態房間創建：

```typescript
// Colyseus: 定義 Room
class MyRoom extends Room {
    onCreate(options: any) {
        // 動態創建房間
    }
    
    onJoin(client: Client, options: any) {
        // 處理玩家加入
    }
}

// 註冊 Room
gameServer.define('my_room', MyRoom)

// 客戶端連接
client.join('my_room', { /* options */ })
```

**特點**：
- 使用 Schema 定義狀態（類似我們的 StateNode）
- 動態房間創建（類似我們的 LandManager）
- 一個 GameServer 可以處理多種 Room 類型

### SwiftStateTree 的設計

**當前設計**：
- 使用泛型綁定 State 類型（編譯時類型安全）
- 一個 `LandServer<State>` 只能處理一種 State 類型
- 需要多個 `LandServer` 實例來處理不同的 State

**改進方向**：
- 使用 `LandRealm` 封裝多個 `LandServer` 實例（支援不同 State 類型）
- 提供類似 Colyseus 的簡化 API
- 保持編譯時類型安全
- **統一入口**：`LandRealm` 可以創建所有的 land state
- 支援分布式架構（每個伺服器創建自己的 `LandRealm`）

## 實作優先順序

### Phase 1：簡化初始化流程（優先）

1. **改進 `LandTypeRegistry`**
   - 支援更靈活的 `landType` 路由
   - 簡化 `landFactory` 和 `initialStateFactory` 的定義

2. **提供 Builder Pattern**
   - 簡化 `LandServer` 的初始化
   - 提供更清晰的 API

### Phase 2：LandRealm 封裝（後續）

1. **`LandTypeRegistry` 已實作** ✅
   - 使用 factory 函數模式管理不同 land type
   - 綁定單一 State 類型
   - 提供 landFactory、initialStateFactory、strategyFactory
   - **定位**：**底層組件**，用於單一 State 類型的上下文
   - **應用場景**：
     - 在 `LandRouter<State>` 中用於根據 `landType` 創建新的 land（單一 State 類型）
     - 在 `MatchmakingService` 中用於獲取對應的 `MatchmakingStrategy`（單一 State 類型）
     - 在 `LobbyContainer` 中用於創建和管理不同類型的 lands（單一 State 類型）
   - **限制**：
     - 所有 land type 必須使用相同的 State 類型
     - 如果不同 land type 需要不同的 State 類型，需要多個 `LandTypeRegistry` 實例
     - 一個 `LandRouter<State>` 只能處理一種 State 類型的所有 land types
   - **與 `LandRealm` 的關係**：
     - `LandRealm` **不使用** `LandTypeRegistry`，因為它需要支援不同 State 類型
     - `LandRealm` 直接使用 `landFactory` 和 `initialStateFactory`，不依賴 `LandTypeRegistry`
     - `LandTypeRegistry` 保留給底層組件（如 `LandRouter<State>`）使用

2. **實作 `LandRealm`**
   - **關鍵特性**：可以管理多個不同 State 類型的 `LandServer` 實例
   - **統一入口**：可以創建所有的 land state
   - 自動管理多個 `LandServer` 實例
   - 提供統一的啟動介面
   - 支援未來分布式架構擴展（規劃中）

3. **更新文檔和範例**
   - 提供使用範例（展示如何管理不同 State 類型）
   - 更新設計文檔

## 總結

### 設計原則

1. **保持類型安全**：使用泛型綁定 State 類型，確保編譯時類型安全
2. **簡化開發者體驗**：提供高層 API，隱藏內部複雜度
3. **靈活性**：支援多種使用場景（單一 State、多種 State、統一 State）

### 當前狀態

- ✅ **State 綁定**：已實作，使用泛型綁定單一 State 類型
- ✅ **命名統一**：所有組件都以 "Land" 開頭，保持命名一致性
- 📅 **命名遷移**：規劃中，`AppContainer` 將作為 `LandServer` 的過時別名
- 📅 **簡化初始化**：規劃中，需要改進 `LandTypeRegistry` 和提供 Builder Pattern
- 📅 **多 State 支援**：規劃中，需要實作 `LandRealm` 封裝（可以管理不同 State 類型的 `LandServer`）
- 📅 **分布式架構**：規劃中，跨伺服器協調和 MatchmakingService 整合仍在設計中

### 下一步

1. 引入 `LandServer<State>`，`AppContainer` 作為別名
2. 標記 `AppContainer` 為 deprecated
3. 改進 `LandTypeRegistry` 支援更靈活的配置
4. 提供 Builder Pattern 簡化初始化
5. **實作 `LandRealm` 封裝多個 `LandServer` 實例（支援不同 State 類型）**
6. **確保 `LandRealm` 可以創建所有的 land state（統一入口）**
7. 設計分布式架構（包括 MatchmakingService 整合）
8. 更新文檔和範例


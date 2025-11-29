# AppContainer & Hosting 設計

> 本文檔說明 SwiftStateTree 在 Server 端的組裝方式：如何將 Runtime / Transport 整合成一個可啟動的環境，並支援 Demo 專案與單元測試重用。
>
> **狀態說明**：
> - ✅ Core / Transport：已實作，使用實際模組命名
- ✅ AppContainer：Demo target 已提供 `AppContainer` 封裝，含 Production/Test 模式
> - 📅 Persistence：未來規劃，目前未實作
>
> 相關文檔：
> - [DESIGN_RUNTIME.md](./DESIGN_RUNTIME.md) - Runtime 結構設計
> - [DESIGN_TRANSPORT.md](./DESIGN_TRANSPORT.md) - Transport 層設計


## 設計目標

### 1. 清楚分層

- ✅ **Core（StateTree、Land DSL）**：不依賴任何 web framework / ORM
- ✅ **Transport（WebSocket / HTTP）**：可以替換（Hummingbird、Vapor、甚至純 NIO）
- 📅 **Persistence（PostgresNIO / ORM）**：未來規劃，獨立在 repository 層

### 2. 可組裝、可測試

- ✅ 可以在 `main.swift` 中組裝整個 server runtime
- ✅ 單元測試可以單獨測試 Runtime 邏輯和 JSON 編碼
- ✅ 已提供統一的 `AppContainer`，簡化組裝流程並支援 Demo / Production / Test

### 3. Demo / Example 可重用

- ✅ 目前有 Demo 專案展示實際使用方式
- ✅ Demo 專案已獨立至 `Examples/` 目錄，保持主專案結構簡潔


## 模組/Target 分層

### 當前 Package 結構

```
SwiftStateTree/
├── Package.swift
├── Sources/
│   ├── SwiftStateTree/                     # ✅ Core: Land DSL, Runtime, Sync
│   ├── SwiftStateTreeTransport/            # ✅ Transport 抽象層
│   ├── SwiftStateTreeHummingbird/          # ✅ Hummingbird WebSocket 適配器
│   ├── SwiftStateTreeMacros/               # ✅ Macro 實作
│   └── (無 Demo target，僅保留 library/adapter)
├── Tests/
│   └── SwiftStateTreeTests/
└── Examples/                               # ✅ Demo 專案獨立於此
    └── SwiftStateTreeHummingbirdDemo/
```

### Core（SwiftStateTree）

**職責**：
- Land DSL / Room DSL
- StateTree Runtime（`LandKeeper`）
- SyncPolicy / 差異計算 / TransportMessage 定義
- State / Action / Event 基礎型別

**依賴**：
- 標準庫
- Concurrency（async/await）
- SwiftStateTreeMacros（編譯時）

**不知道**：
- Hummingbird / Vapor
- Postgres / ORM
- 任何具體的 Web framework / DB driver

### Transport 層

**Target**：`SwiftStateTreeTransport`（抽象層）+ `SwiftStateTreeHummingbird`（Hummingbird 適配器）

**架構分層**：
```
WebSocketTransport (抽象層)
    ↓
TransportAdapter (連接 Runtime 和 Transport)
    ↓
HummingbirdStateTreeAdapter (Hummingbird 適配器)
    ↓
Hummingbird Application
```

**職責**：
- `WebSocketTransport`：定義 WebSocket 連接抽象
- `TransportAdapter`：連接 `LandKeeper` 和 `WebSocketTransport`，處理訊息編解碼
- `HummingbirdStateTreeAdapter`：Hummingbird WebSocket 的具體適配器
- 建立 WebSocket endpoint（例如 `/game`）
- 處理連接生命週期和訊息路由

**依賴**：
- `SwiftStateTree`
- `Hummingbird` / `HummingbirdWebSocket`

### Persistence 層（未來規劃）

**Target**：`SwiftStateTreePersistencePostgres`（📅 尚未實作）

**計劃職責**：
- 使用 `PostgresClient` 建立連線池
- 定義 `DatabaseClient` 作為薄封裝
- 實作各種 repository 協定，例如：
  - `PlayerRepository`
  - `RoomSnapshotRepository`

**原則**：服務 Domain / Runtime，不直接被 Transport 接觸


## Domain & Services 層

### 目前實作：LandServices

當前實作使用 `LandServices` 來注入外部服務到 `LandContext`：

```swift
/// Service abstraction structure (does not depend on HTTP)
///
/// Services are injected at the Transport layer and accessed through LandContext.
/// This allows Land DSL to use services without knowing transport details.
///
/// Currently supports dynamic service registration via type-based lookup.
/// This is a temporary implementation and may be refined in the future.
public struct LandServices: Sendable {
    private var services: [ObjectIdentifier: any Sendable] = [:]
    
    public mutating func register<Service: Sendable>(_ service: Service, as type: Service.Type) {
        services[ObjectIdentifier(type)] = service
    }
    
    public func get<Service: Sendable>(_ type: Service.Type) -> Service? {
        return services[ObjectIdentifier(type)] as? Service
    }
}
```

**設計原則**：
- `LandServices` 支援動態服務註冊，使用類型標識符進行服務查找
- Services 透過 `LandContext` 提供給 Land handlers
- Core 不知道服務的具體實作細節
- Services 在呼叫 `LandKeeper.join()` 時注入，Land DSL 透過 `ctx.services.get(ServiceType.self)` 存取
- 目前實作為暫定版本，後續需要設計更完整的服務管理機制

**使用方式**：

**方式 1：使用動態服務註冊（目前實作）**

目前核心庫已實作支援動態服務註冊的 `LandServices`：

```swift
// 在 Transport 層註冊服務
var services = LandServices()
services.register(userRepository, as: UserRepository.self)
services.register(itemRepository, as: ItemRepository.self)
await keeper.join(playerID: playerID, clientID: clientID, sessionID: sessionID, services: services)

// 在 Land handlers 中使用
Action(SomeAction.self) { state, action, ctx in
    let userRepo = ctx.services.get(UserRepository.self)
    let user = try await userRepo?.load(id: ctx.playerID)
}
```

**⚠️ 注意**：這是目前暫定的實作方式，後續需要設計更完整的服務管理機制，可能包括：
- 服務生命週期管理
- 服務依賴注入
- 服務配置和驗證
- 更好的類型安全保證

**方式 2：透過應用層服務容器管理（替代方案）**

如果不想使用核心庫的服務註冊機制，也可以在應用層建立自己的服務容器：

```swift
// 定義自己的服務容器
public struct GameServices: Sendable {
    public let userRepository: UserRepository
    public let itemRepository: ItemRepository
    public let metricsService: MetricsService
}

// 透過單例或依賴注入在應用層管理
actor ServiceContainer {
    static let shared = ServiceContainer()
    var gameServices: GameServices?
    
    func setGameServices(_ services: GameServices) {
        self.gameServices = services
    }
}

// 在 Land handlers 中存取
Action(SomeAction.self) { state, action, ctx in
    let services = await ServiceContainer.shared.gameServices
    let user = try await services?.userRepository.load(id: ctx.playerID)
}
```

**當前狀態**：
- ✅ `LandServices` 結構已定義，支援動態服務註冊（`register` / `get`）
- ✅ 可在 `LandContext` 中透過 `ctx.services.get(ServiceType.self)` 存取服務
- ✅ 支援在 `LandKeeper.join()` 時注入服務實例
- ⚠️ 目前實作為暫定版本，後續需要設計更完整的服務管理機制（生命週期、依賴注入等）

### 未來規劃：Repository 層（📅 尚未實作）

當實作 Persistence 層時，可以考慮加入 Repository 協定：

```swift
// 未來可能的設計
public protocol PlayerRepository: Sendable {
    func load(id: PlayerID) async throws -> PlayerProfile?
    func save(_ player: PlayerProfile) async throws
}

public struct GameDomainServices: Sendable {
    public let players: PlayerRepository
    // 未來可擴充 items, rooms, matchResults...
    
    public init(players: PlayerRepository) {
        self.players = players
    }
}
```

**設計原則**（未來）：
- Runtime / Land DSL 只透過 `GameDomainServices` 來操作長期資料
- Core 不知道底下是 PostgresNIO、Fluent ORM 或其他服務
- Repository 模式提供清晰的資料存取抽象


## Server 組裝方式

### 目前實作：AppContainer 封裝

- 位置：`Sources/SwiftStateTreeHummingbirdHosting/AppContainer.swift`（target `SwiftStateTreeHummingbirdHosting`，提供泛用 host pattern，Demo 與測試共用）
- 功能：
  - 集中建立 `LandKeeper`、`WebSocketTransport`、`TransportAdapter`、`HummingbirdStateTreeAdapter`、`Router`、`Application`
  - 提供 `Configuration` 結構統一設定 host、port、路徑與是否顯示啟動訊息
  - 內建健康檢查路由，並可透過 `configureRouter` 閉包增加額外 endpoint
  - 具備 `makeServer`（實際 host）與 `makeForTest`（純 transport harness）兩種模式
- 使用方式：

```swift
import SwiftStateTreeHummingbirdHosting

@main
struct HummingbirdDemo {
    static func main() async throws {
        typealias DemoAppContainer = AppContainer<DemoGameState, DemoClientEvents, DemoServerEvents>
        let container = try await DemoAppContainer.makeServer(
            land: DemoGame.makeLand(),
            initialState: DemoGameState()
        )
        try await container.run()
    }
}
```

`run()` 會依設定輸出啟動資訊並呼叫 `Application.runService()`。若需要自訂 port 或路徑：

```swift
let container = try await DemoAppContainer.makeServer(
    configuration: .init(host: "0.0.0.0", port: 8081, webSocketPath: "/ws"),
    land: DemoGame.makeLand(),
    initialState: DemoGameState()
) { router in
    router.get("/metrics") { _, _ in "ok" }
}
```

### 測試專用：`AppContainerForTest`

- `AppContainer.makeForTest(land:initialState:)` 會回傳 `AppContainerForTest`
- 提供 `connect(sessionID:using:)`、`disconnect(sessionID:)`、`send(_:from:)`，方便測試模擬 WebSocket 事件
- 測試可直接取得：
  - `keeper`：驗證 state 變化
  - `transport`：掛上 fake WebSocket 連線
  - `transportAdapter`：針對 transport 層做進一步驗證

```swift
let harness = await DemoAppContainer.makeForTest(
    land: DemoGame.makeLand(),
    initialState: DemoGameState()
)
let connection = RecordingWebSocketConnection()
let session = SessionID("test-session")

await harness.connect(sessionID: session, using: connection)
await harness.send(encodedMessage, from: session)
let state = await harness.keeper.currentState()
```

### 歷史參考：直接在 main.swift 中組裝

在引入 AppContainer 之前，Demo 會於 `main.swift` 逐步 new 出所有組件。該流程仍記錄於本文件做比較，未來維護者可以對照 AppContainer 前後差異。若新場景需要自訂組裝細節，可在 `AppContainer` 的 `configureRouter` 或 `Configuration` 上擴充，而非回到舊版手動組裝。


## Hosting vs 框架選擇：Hummingbird / Vapor

### 當前決策

**官方推薦 host（第一版）**：使用 **Hummingbird** 作為 SwiftStateTree Server 的主要 Hosting 層

**原因**：
- 結構輕量、只做 NIO HTTP + router + middleware
- 很適合讓 SwiftStateTree 自己當「真正的框架主角」，Hummingbird 只當薄 host
- Transport 層已抽象化（`WebSocketTransport`），未來可加上 Vapor host、純 NIO host 等

### 未來擴充

未來可以選擇加上：
- `SwiftStateTreeVapor` 或 `SwiftStateTreeTransportVapor`
- 或額外 Example 專案示範 SwiftStateTree + Vapor + Fluent / REST Admin 介面

**設計優勢**：Transport 層已抽象化，可以很容易替換不同 host，而不影響 Core / Runtime


## 測試策略

### 單元測試（Runtime / JSON 編碼）

目前測試直接建立 `LandKeeper` 和相關組件：
- 不啟動 Hummingbird
- 直接測試 Runtime 邏輯和 JSON 編碼

**測試內容**：
- 呼叫 `LandKeeper` 的 action handler
- 測試 state 變化、sync 邏輯
- 透過 JSONEncoder 編碼 state patch，驗證 JSON 結構

**現狀**：可使用 `AppContainer.makeForTest()` 建立測試環境，重用與實際 host 相同的組裝流程

### Transport 測試

目前已有 `WebSocketConnection` 協議抽象：

```swift
public protocol WebSocketConnection: Sendable {
    func send(_ data: Data) async throws
    func close() async throws
}
```

測試時可以實作 Fake WebSocketConnection，驗證 Transport 層的行為

### 整合測試（可選）

在測試中啟動實際 Hummingbird server：
- 使用 client 連線到 WebSocket endpoint
- 發 action、收 patch
- 適合寫少量「端到端流程」驗證（例如：連接 → 加入 → 發送 action → 接收 state update）


## Examples / Demo 專案結構

### 當前狀況

目前 Demo 專案已獨立至 `Examples/SwiftStateTreeHummingbirdDemo`：

```
Examples/
  SwiftStateTreeHummingbirdDemo/
    ├── Package.swift                    # 獨立的 Package，依賴主專案的 library
    └── Sources/
        ├── DemoContent/
        │   └── DemoDefinitions.swift    # Demo 專用 Land DSL / actions / events
        └── SwiftStateTreeHummingbirdDemo/
            └── main.swift               # Demo 啟動程式（呼叫泛用 AppContainer）
```

**結構原則**：
- ✅ Example 專案 **不放在主 `Sources/` 下**，避免與 library target 混淆
- ✅ Example 擁有自己的 `Package.swift`，依賴根專案的 library
- ✅ 保持主專案結構簡潔，只包含 library 相關的程式碼


## 多房間架構與命名

### 當前限制

目前的 `AppContainer` 設計假設整個應用只有一個房間：
- 建立單一的 `LandKeeper` 實例
- 所有連線的玩家都連到同一個 Land 實例
- 雖然 `LandKeeper` 是 `actor`（thread-safe），但所有操作都在同一個 actor 上序列化

### 多房間架構規劃

**相關文檔**：詳見 [DESIGN_MULTI_ROOM_ARCHITECTURE.md](./DESIGN_MULTI_ROOM_ARCHITECTURE.md)

**設計方向**：

1. **LandContainer（單一房間容器）**：
   - 將目前 `AppContainer` 的功能提取為 `LandContainer`
   - 管理單一房間的完整生命週期
   - 封裝 `LandKeeper`、`TransportAdapter`、`WebSocketTransport`

2. **LandManager（多房間管理器）**：
   - 管理多個 `LandContainer` 實例
   - 提供房間的建立、查詢、銷毀
   - 路由連線到正確的房間
   - 每個房間有獨立的 `LandKeeper`（actor isolation），可並行執行

3. **MatchmakingService（配對服務）**：
   - 獨立於 `LandManager`，負責玩家配對邏輯
   - 根據規則（等級、區域、遊戲模式等）將玩家分組
   - 決定要建立新房間或加入現有房間

4. **LobbyContainer（配對大廳）**：
   - 提供一個固定的「配對大廳」房間
   - 玩家等待配對時的臨時空間
   - 顯示配對狀態、等待中的玩家列表

5. **AppContainer（應用層級容器）**：
   - 管理整個應用的生命週期
   - 組裝所有服務（MatchmakingService、LandManager、LobbyContainer）
   - 支援單房間和多房間兩種模式
   - 提供向後兼容的 API
   - 支援並行處理多個房間（使用 `withTaskGroup`）

### 命名建議

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

## 總結

### 當前實作狀態

1. **Core / Transport 層已實作並分層清楚**：
   - ✅ Core (`SwiftStateTree`) 不依賴任何 web framework / ORM
   - ✅ Transport 層已抽象化，可替換不同 host（目前使用 Hummingbird）
   - ✅ 使用 `LandServices` 注入外部服務到 Runtime

2. **組裝方式**：
   - ✅ Demo target 透過 `AppContainer` 統一組裝，`main.swift` 僅負責呼叫
   - ✅ 測試可透過 `AppContainerForTest` 共用相同 wiring
   - ⚠️ 目前僅支援單一房間模式

3. **測試**：
   - ✅ 可以單獨測試 Runtime 邏輯
   - ✅ Transport 層已抽象化，支援測試替換

### 未來規劃

1. **多房間架構**（📅 規劃中）：
   - 實作 `LandContainer` 和 `LandManager` 支援多房間
   - 實作 `MatchmakingService` 和 `LobbyContainer` 支援配對
   - 實作並行執行支援（使用 `withTaskGroup` 並行處理多個房間的 tick 和事件）
   - 詳見 [DESIGN_MULTI_ROOM_ARCHITECTURE.md](./DESIGN_MULTI_ROOM_ARCHITECTURE.md)

2. **Persistence 層**（📅 尚未實作）：
   - 未來可加入 `SwiftStateTreePersistencePostgres` 模組
   - 實作 Repository 模式，提供資料存取抽象

3. **AppContainer 擴充**（🔄 建議）：
   - 待 Persistence/Domain Services 可用時，擴充 `Configuration` 注入對應服務
   - 視需要提供 Vapor/NIO host 版本的 Container
   - 重構為應用層級容器，支援多房間架構

4. **Demo 專案獨立**（✅ 已完成）：
  - Hummingbird Demo 位於 `Examples/SwiftStateTreeHummingbirdDemo`
  - 主專案 `Sources/` 僅保留 library/transport 程式碼

### 設計優勢

透過這種分層設計：
- ✅ 可以在單元測試裡跑真正的 Runtime、產生實際 JSON，再做驗證
- ✅ Transport 層抽象化，易於替換不同的 web framework
- ✅ Example / Demo 已拆出 `Examples/`，可共用 `AppContainer` 作為啟動模板
- 📅 未來可擴展為多房間架構，支援大型多人遊戲場景


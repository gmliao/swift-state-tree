# AppContainer & Hosting 設計

> 本文檔說明 SwiftStateTree 在 Server 端的組裝方式：如何將 Runtime / Transport 整合成一個可啟動的環境，並支援 Demo 專案與單元測試重用。
>
> **狀態說明**：
> - ✅ Core / Transport：已實作，使用實際模組命名
> - 🔄 AppContainer：建議的封裝方式，未來可實作以簡化組裝流程
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
- 🔄 未來可考慮統一的 `AppContainer`，簡化組裝流程並支援不同環境配置

### 3. Demo / Example 可重用

- ✅ 目前有 Demo 專案展示實際使用方式
- 🔄 未來 Demo 專案應獨立至 `Examples/` 目錄，保持主專案結構簡潔


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
│   └── SwiftStateTreeHummingbirdDemo/      # 🔄 Demo（建議移至 Examples/）
├── Tests/
│   └── SwiftStateTreeTests/
└── Examples/                               # 📅 未來：Demo 專案應獨立至此
    └── [Demo 專案]/
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

### 目前實作：直接在 main.swift 中組裝

目前 Demo 專案在 `main.swift` 中直接組裝所有組件：

```swift
// 1. Setup Transport Layer
let transport = WebSocketTransport()

// 2. Setup LandKeeper with callbacks
let keeper = LandKeeper<State, ClientE, ServerE>(
    definition: landDefinition,
    initialState: DemoGameState(),
    sendEvent: { event, target in
        await adapterHolder.adapter?.sendEvent(event, to: target)
    },
    syncNow: {
        await adapterHolder.adapter?.syncNow()
    }
)

// 3. Setup TransportAdapter (connects LandKeeper and Transport)
let transportAdapter = TransportAdapter<State, ClientE, ServerE>(
    keeper: keeper,
    transport: transport,
    landID: landDefinition.id
)

// 4. Setup Hummingbird Adapter
let hbAdapter = HummingbirdStateTreeAdapter(transport: transport)

// 5. Setup Hummingbird Router and Application
let router = Router(context: BasicWebSocketRequestContext.self)
router.ws("/game") { inbound, outbound, context in
    await hbAdapter.handle(inbound: inbound, outbound: outbound, context: context)
}

let app = Application(router: router, configuration: .init(...))
try await app.runService()
```

**組裝流程說明**：
1. 建立 `WebSocketTransport`（Transport 抽象層）
2. 建立 `LandKeeper`（Runtime），注入 sendEvent 和 syncNow 回調
3. 建立 `TransportAdapter`（連接 Runtime 和 Transport）
4. 建立 `HummingbirdStateTreeAdapter`（Hummingbird 適配器）
5. 設定 Hummingbird router 和 application

### 未來規劃：AppContainer 封裝（🔄 建議）

**AppContainer** = 一個「把整個 server 組裝起來的容器」，負責：

- 建立：
  - Logger
  - Runtime（LandKeeper）
  - Transport 層組件
  - 未來：DB client、Repository 實作、Domain services

- 提供不同模式：
  - `makeProduction()`：正式環境
  - `makeForTest()`：單元/整合測試
  - `makeDemo()`：Example 用

**未來可能的 AppContainer 結構**（放在 Demo 專案裡）：

```swift
public struct AppContainer {
    public let keeper: LandKeeper<State, ClientE, ServerE>
    public let transport: WebSocketTransport
    public let transportAdapter: TransportAdapter<State, ClientE, ServerE>
    public let hbAdapter: HummingbirdStateTreeAdapter
    // 未來：public let dbClient: DatabaseClient
    // 未來：public let domain: GameDomainServices
    
    // 正式環境組裝
    public static func makeProduction() async throws -> AppContainer {
        // 組裝所有組件...
    }
    
    // 測試用組裝
    public static func makeForTest() -> AppContainerForTest {
        // 使用測試配置...
    }
}
```

**優點**：
- 統一組裝流程，減少重複程式碼
- 更容易在不同環境（Production / Test / Demo）間切換
- 未來加入 Persistence 層時更容易整合


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

**未來**：當實作 `AppContainer` 後，可以使用 `AppContainer.makeForTest()` 建立測試環境

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

目前 Demo 專案位於：
```
Sources/SwiftStateTreeHummingbirdDemo/
  └── main.swift
```

### 建議結構（未來重構）

Demo 專案應該獨立到 `Examples/` 目錄下：

```
Examples/
  SwiftStateTreeHummingbirdDemo/
    ├── Package.swift                    # 獨立的 Package，依賴主專案的 library
    └── Sources/
        └── SwiftStateTreeHummingbirdDemo/
            ├── main.swift               # Demo 啟動程式
            └── AppContainer.swift       # 未來：AppContainer 封裝（可選）
```

**建議原則**：
- ✅ Example 專案 **不放在主 `Sources/` 下**，避免與 library target 混淆
- ✅ Example 擁有自己的 `Package.swift`，依賴根專案的 library
- ✅ 保持主專案結構簡潔，只包含 library 相關的程式碼


## 總結

### 當前實作狀態

1. **Core / Transport 層已實作並分層清楚**：
   - ✅ Core (`SwiftStateTree`) 不依賴任何 web framework / ORM
   - ✅ Transport 層已抽象化，可替換不同 host（目前使用 Hummingbird）
   - ✅ 使用 `LandServices` 注入外部服務到 Runtime

2. **組裝方式**：
   - 目前在 `main.swift` 中直接組裝所有組件
   - 🔄 未來可考慮實作 `AppContainer` 封裝以簡化組裝流程

3. **測試**：
   - ✅ 可以單獨測試 Runtime 邏輯
   - ✅ Transport 層已抽象化，支援測試替換

### 未來規劃

1. **Persistence 層**（📅 尚未實作）：
   - 未來可加入 `SwiftStateTreePersistencePostgres` 模組
   - 實作 Repository 模式，提供資料存取抽象

2. **AppContainer 封裝**（🔄 建議）：
   - 統一組裝流程，支援 Production / Test / Demo 不同配置
   - 未來加入 Persistence 層時更容易整合

3. **Demo 專案獨立**（🔄 建議）：
   - 將 Demo 從 `Sources/` 移至 `Examples/` 目錄
   - 保持主專案結構簡潔

### 設計優勢

透過這種分層設計：
- ✅ 可以在單元測試裡跑真正的 Runtime、產生實際 JSON，再做驗證
- ✅ Transport 層抽象化，易於替換不同的 web framework
- 🔄 未來 Example / Demo 可以重用相同的組裝流程，對外展示會更乾淨一致


[English](FAQ.md) | [中文版](FAQ.zh-TW.md)

# 常見問題 (FAQ)

> SwiftStateTree 使用過程中的常見問題與解答

## 安裝與設定

### Q: 如何開始使用 SwiftStateTree？

A: 目前建議直接 clone 專案來體驗：

```bash
git clone https://github.com/your-username/SwiftStateTree.git
cd SwiftStateTree
swift build
```

詳細說明請參考 [README.md](../README.md#快速開始)。

### Q: 系統要求是什麼？

A: 
- Swift 6.0+
- macOS 14.0+（開發環境）
- 支援 Swift 6 的平台（部署環境）

### Q: 如何確認專案可以正常運行？

A: 運行測試：

```bash
swift test
```

如果測試通過，表示專案可以正常運行。你也可以嘗試運行範例：

```bash
cd Examples/HummingbirdDemo
swift run DemoServer
```

## StateTree 定義

### Q: 為什麼所有 stored property 都必須標記 `@Sync` 或 `@Internal`？

A: 這是 `@StateNodeBuilder` 的驗證規則，確保所有狀態欄位都有明確的同步策略。這樣可以：

- 避免意外洩露敏感資料
- 明確控制同步行為
- 提升程式碼可讀性

**範例**：

```swift
@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:] // ✅ 正確
    
    @Internal
    var lastProcessedTimestamp: Date = Date() // ✅ 正確
    
    // var tempData: String = "" // ❌ 錯誤：未標記
}
```

### Q: Computed properties 需要標記嗎？

A: 不需要。Computed properties 會自動跳過驗證，因為它們不儲存狀態。

```swift
@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]
    
    // Computed property 不需要標記
    var totalPlayers: Int {
        players.count
    }
}
```

### Q: `@Sync(.serverOnly)` 和 `@Internal` 有什麼差別？

A: 
- **`@Sync(.serverOnly)`**：不同步給 client，但同步引擎會知道這個欄位（用於驗證和追蹤）
- **`@Internal`**：完全不需要同步引擎知道，純粹伺服器內部使用

**使用建議**：
- 需要同步引擎追蹤但不同步給 client → 使用 `@Sync(.serverOnly)`
- 純粹內部計算用的暫存值 → 使用 `@Internal`

## 同步規則

### Q: 如何選擇合適的同步策略？

A: 根據資料特性選擇：

| 策略 | 適用場景 | 範例 |
|------|---------|------|
| `.broadcast` | 所有玩家需要相同資料 | 遊戲狀態、房間資訊 |
| `.perPlayerSlice()` | Dictionary 只同步該玩家的部分 | 手牌、個人資料 |
| `.perPlayer(...)` | 需要依玩家過濾 | 個人任務進度 |
| `.serverOnly` | 伺服器內部用，不同步 | 隱藏牌組、內部計數器 |
| `.custom(...)` | 完全自定義過濾邏輯 | 複雜的權限控制 |

### Q: 同步效能如何優化？

A: 
1. **使用 `@SnapshotConvertible`**：為巢狀結構標記此 macro，避免 runtime reflection
2. **啟用 dirty tracking**：只同步變更的欄位（預設啟用）
3. **合理使用 `@Internal`**：內部計算用的欄位不要標記 `@Sync`

詳細說明請參考 [同步規則](core/sync.zh-TW.md)。

## Land DSL

### Q: 如何在 handler 中執行 async 操作？

A: 為了 determinism，handlers 以同步方式設計，**不建議在 handler 內直接做 async I/O**。

請改用 Resolver 在 handler 執行前載入資料，並用 `ctx.emitEvent(...)` 產生 deterministic 輸出：

```swift
struct LoadSomethingResolver: ContextResolver {
    struct Output: ResolverOutput { let value: Int }
    static func resolve(ctx: ResolverContext) async throws -> Output {
        let value = try await someAsyncOperation()
        return Output(value: value)
    }
}

Rules {
    HandleAction(SomeAction.self, resolvers: LoadSomethingResolver.self) { state, action, ctx in
        let output: LoadSomethingResolver.Output? = ctx.loadSomething
        state.someField = output?.value ?? 0

        ctx.emitEvent(SomeEvent(result: state.someField), to: .player(ctx.playerID))
        return SomeResponse()
    }
}
```

### Q: 如何處理錯誤？

A: 在 handler 中拋出錯誤，會被自動包裝成 `ErrorPayload` 回傳給 client：

```swift
Rules {
    HandleAction(JoinAction.self) { state, action, ctx in
        // 驗證
        guard action.playerID != nil else {
            throw LandError.invalidAction("playerID is required")
        }
        
        // 檢查房間是否已滿
        if state.players.count >= 4 {
            throw LandError.joinDenied("Room is full")
        }
        
        // 正常處理
        state.players[action.playerID] = PlayerState(name: action.name)
        return JoinResponse(status: "ok")
    }
}
```

### Q: CanJoin 和 OnJoin 的差別是什麼？

A: 
- **`CanJoin`**：加入前的驗證，可以拒絕加入（回傳 `.deny`）
- **`OnJoin`**：加入後的處理，一定會執行（除非 CanJoin 拒絕）

**範例**：

```swift
Rules {
    CanJoin { state, ctx in
        // 驗證邏輯
        if state.players.count >= 4 {
            return .deny(reason: "Room is full")
        }
        return .allow
    }
    
    OnJoin { state, ctx in
        // 加入後的初始化
        state.players[ctx.playerID] = PlayerState(name: ctx.playerID.rawValue)
    }
}
```

## 錯誤處理

### Q: 常見的錯誤碼有哪些？

A: 主要錯誤碼包括：

**Join 錯誤**：
- `JOIN_SESSION_NOT_CONNECTED`：連線未建立
- `JOIN_ALREADY_JOINED`：已經加入
- `JOIN_DENIED`：加入被拒絕
- `JOIN_ROOM_FULL`：房間已滿
- `JOIN_ROOM_NOT_FOUND`：房間不存在

**Action 錯誤**：
- `ACTION_NOT_REGISTERED`：Action 未註冊
- `ACTION_INVALID_PAYLOAD`：Payload 格式錯誤
- `ACTION_HANDLER_ERROR`：Handler 執行錯誤

**Event 錯誤**：
- `EVENT_NOT_REGISTERED`：Event 未註冊
- `EVENT_INVALID_PAYLOAD`：Payload 格式錯誤

**訊息格式錯誤**：
- `INVALID_MESSAGE_FORMAT`：訊息格式無效
- `INVALID_JSON`：JSON 解析失敗
- `MISSING_REQUIRED_FIELD`：缺少必要欄位

### Q: 如何處理 Resolver 錯誤？

A: Resolver 錯誤會被自動包裝並回傳給 client：

```swift
struct ProductInfoResolver: ContextResolver {
    typealias Output = ProductInfo
    
    static func resolve(ctx: ResolverContext) async throws -> ProductInfo {
        guard let productID = ctx.actionPayload.productID else {
            throw ResolverError.missingParameter("productID")
        }
        
        // 如果找不到產品，拋出錯誤
        guard let product = await fetchProduct(productID) else {
            throw ResolverError.dataLoadFailed("Product not found")
        }
        
        return product
    }
}
```

錯誤會被包裝在 `ResolverExecutionError` 中，包含 resolver 名稱和原始錯誤。

## 效能問題

### Q: 如何提升同步效能？

A: 
1. **使用 `@SnapshotConvertible`**：為頻繁使用的巢狀結構標記此 macro
2. **啟用 dirty tracking**：只同步變更的欄位（預設啟用）
3. **合理設計 StateTree**：避免過深的巢狀結構
4. **使用 `@Internal`**：內部計算用的欄位不要同步

詳細說明請參考 [Macros](macros/README.zh-TW.md)。

### Q: 什麼時候應該關閉 dirty tracking？

A: 當大部分欄位在每次更新時都會變更時，關閉 dirty tracking 可能更快。但通常建議保持開啟。

```swift
// 在 TransportAdapter 初始化時設定
let adapter = TransportAdapter(
    keeper: keeper,
    transport: transport,
    landID: landID,
    enableDirtyTracking: false // 關閉 dirty tracking
)
```

## 多房間架構

### Q: 如何實作多房間架構？

A: 使用 `LandManager` 和 `LandRouter`：

```swift
// 建立 LandManager
let landManager = LandManager<GameState>(
    landFactory: { landID in
        createGameLand(landID: landID)
    },
    initialStateFactory: { landID in
        GameState()
    }
)

// 建立 LandRouter
let router = LandRouter<GameState>(
    landManager: landManager,
    landTypeRegistry: landTypeRegistry
)
```

詳細說明請參考 [Transport 層](transport/README.zh-TW.md)。

### Q: 如何管理房間生命週期？

A: 在 Land DSL 中使用 `Lifetime` 區塊：

```swift
Lifetime {
    // 房間空閒 60 秒後自動銷毀
    DestroyWhenEmpty(after: .seconds(60))
    
    // 房間存在超過 1 小時後銷毀
    DestroyAfter(duration: .hours(1))
}
```

## 認證與安全性

### Q: 如何設定 JWT 認證？

A: 使用 `LandServerConfiguration` 並通過 `LandHost` 註冊：

```swift
// Create JWT configuration
let jwtConfig = JWTConfiguration(
    secretKey: "your-secret-key",
    algorithm: .HS256,
    validateExpiration: true
)

// Create LandHost
let host = LandHost(configuration: LandHost.HostConfiguration(
    host: "localhost",
    port: 8080
))

// Register land type with JWT configuration
try await host.register(
    landType: "demo",
    land: demoLand,
    initialState: GameState(),
    webSocketPath: "/game",
    configuration: LandServerConfiguration(
        jwtConfig: jwtConfig,
        allowGuestMode: true // 允許 Guest 模式
    )
)

try await host.run()
```

詳細說明請參考 [認證機制](hummingbird/auth.zh-TW.md)。

### Q: Guest 模式和 JWT 的優先順序是什麼？

A: PlayerSession 欄位優先序：

1. join request 內容
2. JWT payload
3. guest session

## 除錯技巧

### Q: 如何除錯同步問題？

A: 
1. 檢查 `@Sync` 標記是否正確
2. 確認 dirty tracking 是否啟用
3. 查看 SyncEngine 的日誌
4. 使用 `ctx.requestSyncNow()` 請求 deterministic 的同步（於 tick 結尾 flush）

### Q: 如何查看狀態變更？

A: 在 handler 中使用 `ctx.logger` 添加日誌：

```swift
Rules {
    HandleAction(SomeAction.self) { state, action, ctx in
        ctx.logger.debug("Before state change", metadata: [
            "field": "\(state.someField)"
        ])
        state.someField = action.value
        ctx.logger.debug("After state change", metadata: [
            "field": "\(state.someField)"
        ])
        return SomeResponse()
    }
}
```

**注意**：`ctx.logger` 是 Swift Logging 框架的 `Logger` 實例，支援不同日誌級別（`.debug`, `.info`, `.warning`, `.error`）和結構化 metadata。

### Q: 如何測試 Land 定義？

A: 使用 Swift Testing 框架：

```swift
import Testing
@testable import SwiftStateTree

@Test("Test Land behavior")
func testLand() async throws {
    let land = createTestLand()
    let keeper = LandKeeper(definition: land, initialState: TestState())
    
    // 測試邏輯
    // ...
}
```

## 其他問題

### Q: 可以同時使用多個 Land 嗎？

A: 可以。在多房間模式下，每個房間都是獨立的 Land 實例。

### Q: 如何遷移舊版本的 StateTree？

A: 使用 `@Since` 標記和 Persistence 層處理版本差異。詳細說明請參考設計文檔。

### Q: 支援分散式部署嗎？

A: 目前版本專注於單節點部署。分散式部署是未來規劃的功能。

## 相關文檔

- [快速開始](quickstart.zh-TW.md) - 基本使用範例
- [核心概念](core/README.zh-TW.md) - 深入了解系統設計
- [同步規則](core/sync.zh-TW.md) - 同步機制詳解
- [Land DSL](core/land-dsl.zh-TW.md) - Land 定義指南
- [Transport 層](transport/README.zh-TW.md) - 網路傳輸詳解

## 尋求幫助

如果以上問題無法解決你的疑問，請：

1. 查看 [設計文檔](../Notes/design/) 了解系統設計
2. 查看 [範例程式碼](../Examples/) 參考實作方式
3. 提交 [Issue](https://github.com/your-username/SwiftStateTree/issues) 尋求協助


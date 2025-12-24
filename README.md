# SwiftStateTree

一個基於 Swift 的狀態樹（State Tree）遊戲引擎庫，採用 **單一 StateTree + 同步規則 + Land DSL** 的設計理念。

## 📋 目錄

- [設計理念](#設計理念)
- [系統要求](#系統要求)
- [安裝](#安裝)
- [快速開始](#快速開始)
- [專案結構](#專案結構)
- [核心概念](#核心概念)
- [開發指南](#開發指南)
- [設計文檔](#設計文檔)
- [貢獻](#貢獻)
- [許可證](#許可證)

## 🎯 設計理念

SwiftStateTree 採用以下核心設計：

- 🌳 **單一權威狀態樹**：用一棵 `StateTree` 表示整個領域的狀態
- 🔄 **同步規則 DSL**：使用 `@Sync` 規則控制伺服器要把哪些資料同步給誰
- 🏛️ **Land DSL**：定義領域、Action/Event 處理、Tick 設定
- 💻 **UI 計算交給客戶端**：伺服器只送「邏輯資料」，UI 渲染由客戶端處理

### 模組架構

| 模組 | 說明 |
|------|------|
| **SwiftStateTree** | 核心模組（StateTree、Land DSL、Sync、Runtime、SchemaGen） |
| **SwiftStateTreeTransport** | Transport 層（WebSocketTransport、TransportAdapter、Land 管理） |
| **SwiftStateTreeHummingbird** | Hummingbird 整合（LandServer、JWT/Guest、Admin 路由） |
| **SwiftStateTreeMatchmaking** | Matchmaking 與 Lobby 支援 |
| **SwiftStateTreeMacros** | 編譯期 Macro（@StateNodeBuilder/@Payload/@SnapshotConvertible） |
| **SwiftStateTreeBenchmarks** | 基準測試執行檔 |

## 📦 系統要求

- Swift 6.0+
- macOS 14.0+
- Xcode 15.0+（推薦）

## 🚀 安裝

### Swift Package Manager

在你的 `Package.swift` 中添加依賴：

```swift
dependencies: [
    .package(url: "https://github.com/your-username/SwiftStateTree.git", from: "1.0.0")
]
```

或者在 Xcode 中：
1. File → Add Packages...
2. 輸入倉庫 URL
3. 選擇版本並添加

## 🏃 快速開始

### 1. 克隆倉庫

```bash
git clone https://github.com/your-username/SwiftStateTree.git
cd SwiftStateTree
```

### 2. 構建專案

```bash
swift build
```

### 3. 運行測試

```bash
swift test
```

## 📁 專案結構

### 模組架構

本專案採用模組化設計，對外以以下模組組成為主：

| 模組 | 說明 |
|------|------|
| `SwiftStateTree` | 核心模組（StateTree、Land DSL、Sync、Runtime、SchemaGen） |
| `SwiftStateTreeTransport` | Transport 層（WebSocketTransport、TransportAdapter、Land 管理） |
| `SwiftStateTreeHummingbird` | Hummingbird 整合（LandServer、JWT/Guest、Admin 路由） |
| `SwiftStateTreeMatchmaking` | Matchmaking 與 Lobby 支援 |
| `SwiftStateTreeMacros` | 編譯期 Macro（@StateNodeBuilder/@Payload/@SnapshotConvertible） |
| `SwiftStateTreeBenchmarks` | 基準測試執行檔 |

### 目錄結構

```
SwiftStateTree/
├── Sources/
│   ├── SwiftStateTree/              # core：核心模組
│   │   ├── Action/                  # ActionPayload protocol（核心通訊概念）
│   │   ├── Event/                   # EventPayload protocols（核心通訊概念）
│   │   ├── State/                   # StateProtocol（核心狀態概念）
│   │   ├── StateTree/               # StateTree 定義（StateNode、StateTreeEngine）
│   │   ├── Sync/                    # @Sync 同步規則（SyncPolicy、SyncEngine）
│   │   ├── Land/                   # Land DSL（LandDefinition、LandContext）
│   │   ├── Runtime/                 # Runtime 執行器（LandKeeper）
│   │   ├── Resolver/               # Resolver 機制
│   │   ├── SchemaGen/              # Schema 生成器（JSON Schema）
│   │   └── Support/                # 工具類（AnyCodable 等）
│   │
│   ├── SwiftStateTreeTransport/     # transport：網路傳輸模組
│   │   ├── Transport/              # Transport 協議（GameTransport）
│   │   ├── WebSocket/              # WebSocket 實作（WebSocketTransport）
│   │   └── Connection/             # 連接管理（三層識別）
│   │
│   ├── SwiftStateTreeHummingbird/   # Hummingbird 整合模組
│   ├── SwiftStateTreeMatchmaking/  # Matchmaking/Lobby 模組
│   ├── SwiftStateTreeMacros/       # Macro 實作
│   └── SwiftStateTreeBenchmarks/   # 基準測試執行檔
│
├── Tests/
│   ├── SwiftStateTreeTests/        # core 測試
│   ├── SwiftStateTreeTransportTests/ # transport 測試
│   ├── SwiftStateTreeHummingbirdTests/ # Hummingbird 測試
│   ├── SwiftStateTreeMatchmakingTests/ # Matchmaking 測試
│   └── SwiftStateTreeMacrosTests/ # Macro 測試
│
└── Examples/                        # 範例專案（可選）
    └── HummingbirdDemo/             # Hummingbird 範例
```

> 文件正在整理中，請先參考 `docs/index.md`。舊版文件暫留於 `docs/design`、`docs/guides`、`docs/performance`、`docs/protocol`。

## 💡 核心概念

### StateTree：單一權威狀態樹

```swift
@StateNodeBuilder
struct GameStateTree: StateNodeProtocol {
    // 所有玩家的公開狀態（血量、名字等），可以廣播給大家
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]
    
    // 手牌：每個玩家只看得到自己的
    @Sync(.perPlayerSlice())
    var hands: [PlayerID: HandState] = [:]
    
    // 伺服器內部用，不同步給任何 Client（但仍會被同步引擎知道）
    @Sync(.serverOnly)
    var hiddenDeck: [Card] = []
    
    // 伺服器內部計算用的暫存值（不需要同步引擎知道）
    @Internal
    var lastProcessedTimestamp: Date = Date()
    
    // 計算屬性：自動跳過驗證
    var totalPlayers: Int {
        players.count
    }
}
```

### 同步規則：@Sync 與 @Internal

使用 `@Sync` 屬性標記需要同步的欄位，定義同步策略：

- `.broadcast`：同一份資料同步給所有 client
- `.serverOnly`：伺服器內部用，不同步給 Client（但仍會被同步引擎知道）
- `.perPlayer((Value, PlayerID) -> Value?)`：依玩家與值做過濾（回傳相同型別或 nil）
- `.perPlayerSlice()`：Dictionary 只同步該玩家的 slice（適合 `[PlayerID: Value]`）
- `.masked((Value) -> Value)`：同型別遮罩（所有玩家同值）
- `.custom((PlayerID, Value) -> Value?)`：完全客製化（回傳相同型別或 nil）

使用 `@Internal` 標記伺服器內部使用的欄位（不需要同步引擎知道）：

- 純粹伺服器內部計算用的暫存值、快取等
- 驗證機制會自動跳過
- 與 `@Sync(.serverOnly)` 的差異：`@Internal` 完全不需要同步引擎知道

**驗證規則**：
- 所有 stored properties 必須明確標記（`@Sync` 或 `@Internal`）
- Computed properties 自動跳過驗證

### 效能優化：@SnapshotConvertible

對於在 StateTree 中使用的巢狀結構（如 `PlayerState`、`Card` 等），可以使用 `@SnapshotConvertible` Macro 自動生成 `SnapshotValueConvertible` protocol 實作，避免使用 runtime reflection（Mirror），大幅提升效能。

**使用方式**：

```swift
// 只需要標記 @SnapshotConvertible
@SnapshotConvertible
struct PlayerState: Codable {
    var name: String
    var hpCurrent: Int
    var hpMax: Int
}

// Macro 自動生成 protocol 實作
// extension PlayerState: SnapshotValueConvertible {
//     func toSnapshotValue() throws -> SnapshotValue {
//         return .object([
//             "name": .string(name),
//             "hpCurrent": .int(hpCurrent),
//             "hpMax": .int(hpMax)
//         ])
//     }
// }
```

**效能優勢**：
- ✅ 基本型別（String, Int, Bool 等）直接轉換，避免 Mirror
- ✅ 自動生成，無需手寫程式碼
- ✅ 編譯時生成，型別安全
- ✅ 巢狀結構會優先檢查 protocol，完全避免 Mirror

**適用場景**：
- 在 StateTree 中頻繁使用的巢狀結構
- 需要高效能轉換的使用者定義型別
- 複雜的巢狀結構（多層級）

### Land DSL：領域定義

```swift
let matchLand = Land("match-3", using: GameStateTree.self) {
    AccessControl {
        MaxPlayers(4)
    }
    
    Lifetime {
        Tick(every: .milliseconds(100)) { state, ctx in
            state.stepSimulation()
        }
        DestroyWhenEmpty(after: .seconds(60))
    }
    
    Rules {
        HandleAction(JoinAction.self) { state, action, ctx in
            state.players[action.playerID] = PlayerState(name: action.name, hpCurrent: 100, hpMax: 100)
            return JoinResponse(status: "ok")
        }
        
        HandleEvent(HeartbeatEvent.self) { state, event, ctx in
            state.playerLastActivity[ctx.playerID] = event.timestamp
        }
    }
}
```

## 🛠 開發指南

### 定義 StateTree

在 `Sources/SwiftStateTree/` 中定義你的狀態樹：

```swift
@StateNodeBuilder
public struct GameStateTree: StateNodeProtocol {
    @Sync(.broadcast)
    public var players: [PlayerID: PlayerState]
    
    @Sync(.perPlayerSlice())
    public var hands: [PlayerID: HandState]
}
```

### 定義 Land

使用 Land DSL 定義領域邏輯：

```swift
let gameLand = Land("game-room", using: GameStateTree.self) {
    AccessControl {
        MaxPlayers(4)
    }
    
    Lifetime {
        Tick(every: .milliseconds(100)) { state, ctx in
            state.stepSimulation()
        }
    }
    
    Rules {
        HandleAction(GameAction.self) { state, action, ctx in
            // Handle Action
            return GameActionResponse()
        }
        
        HandleEvent(ClientEvent.self) { state, event, ctx in
            // Handle Event
        }
    }
}
```

## 📚 文件

整理後的 release 文件集中於 `docs/`：

- `docs/index.md`：文件索引與閱讀順序
- `docs/overview.md`：專案總覽與模組圖
- `docs/quickstart.md`：最小可行流程

舊版設計與效能文件暫留於：
- `Notes/design/`
- `Notes/guides/`
- `Notes/performance/`
- `Notes/protocol/`

## 🧪 測試

本專案使用 **Swift Testing**（Swift 6 的新測試框架）進行單元測試。

### 運行測試

運行所有測試：

```bash
swift test
```

運行特定測試：

```bash
swift test --filter StateTreeTests.testGetSyncFields
```

### 編寫新測試

在 `Tests/SwiftStateTreeTests/` 中添加測試用例：

```swift
import Testing
@testable import SwiftStateTree

@Test("Description of what is being tested")
func testYourFeature() throws {
    // Arrange
    let state = YourStateTree()
    
    // Act
    let result = state.someMethod()
    
    // Assert
    #expect(result == expectedValue)
}
```

### 測試框架說明

- **使用 Swift Testing**：Swift 6 的新測試框架，提供更現代的測試體驗
- **`@Test` 屬性**：標記測試函數，可選描述文字
- **`#expect()`**：用於斷言，替代 `XCTAssert*`
- **`Issue.record()`**：記錄測試失敗資訊

## 🤝 貢獻

歡迎貢獻代碼！請遵循以下步驟：

1. Fork 本倉庫
2. 創建特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 開啟 Pull Request

### 代碼規範

- 遵循 Swift API 設計指南
- 使用 Swift 6 並發特性（Actor、async/await）
- 確保所有公開 API 符合 `Sendable`
- 為新功能添加測試用例
- **所有程式碼註解必須使用英文**（包括 `///` 文檔註解和 `//` 行內註解）
- 回覆問題請使用繁體中文；如需程式碼範例或註解，註解請保持英文

## 📄 許可證

本專案採用 MIT 許可證。詳見 [LICENSE](LICENSE) 文件。

## 🔗 相關鏈接

- [Swift 官方文檔](https://swift.org/documentation/)
- [Swift Concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/)

## 📧 聯繫方式

如有問題或建議，請通過以下方式聯繫：

- 提交 [Issue](https://github.com/your-username/SwiftStateTree/issues)

---

**注意**：本專案正在積極開發中，API 可能會發生變化。建議在生產環境使用前仔細測試。
